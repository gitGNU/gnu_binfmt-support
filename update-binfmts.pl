#! /usr/bin/perl -w

# Copyright (c) 2000-2001 Colin Watson <cjwatson@debian.org>.
# See update-binfmts(8) for documentation.

use strict;

use Errno qw(ENOENT);
use POSIX qw(uname);

my $VERSION = '@VERSION@';

my $test;
my %test_installed;
my $admindir = '/var/lib/binfmts';
my $package;
my $mode;
my ($name, $interpreter);
my $type;
my ($magic, $mask, $offset, $extension);

my $procdir = '/proc/sys/fs/binfmt_misc';
my $register = "$procdir/register";

local *BINFMT;

# Format output nicely.
sub wrap ($)
{
    my $text = shift;
    $text =~ s/^(.{0,79})\s/$1\n/gm;
    return $text;
}

# Various "print something and exit" routines.

sub quit ($;@)
{
    print STDERR wrap "update-binfmts: @_\n";
    exit 2;
}

sub version ()
{
    print "Debian GNU update-binfmts $VERSION.\n"
	or quit "unable to write version message: $!";
}

sub usage ()
{
    version;
    print <<EOF
Copyright (c) 2000-2001 Colin Watson. This is free software; see the GNU
General Public License version 2 or later for copying conditions.

Usage:

  update-binfmts [options] --install <name> <path> <spec>
  update-binfmts [options] --remove <name> <path>
  update-binfmts [options] --display [<name>]
  update-binfmts [options] --enable [<name>]
  update-binfmts [options] --disable [<name>]

  where <spec> is one of:

    --magic <byte-sequence> [--mask <byte-sequence>] [--offset <offset>]
    --extension <extension>

Options:

    --package <package-name>    for --install and --remove, specify the
                                current package name
    --admindir <directory>      use <directory> instead of /var/lib/binfmts
                                as administration directory
    --test                      don't do anything, just demonstrate
    --help                      print this help screen and exit
    --version                   output version and exit

EOF
	or quit "unable to write usage message: $!";
}

sub usage_quit ($;@)
{
    print STDERR wrap "update-binfmts: @_\n\n";
    usage;
    exit 2;
}

sub check_supported_os ()
{
    my $sysname = (uname)[0];
    return if $sysname eq 'Linux';
    print <<EOF;
Sorry, update-binfmts currently only works on Linux.
EOF
    if ($sysname eq 'GNU')
    {
	print <<EOF;
Patches for Hurd support are welcomed; they should not be difficult.
EOF
    }
    exit 2;
}

# Something has gone wrong, but not badly enough for us to give up.
sub warning ($;@) {
    print STDERR wrap "update-binfmts: warning: @_\n";
}

# Make sure options are unambiguous.

sub check_modes ($)
{
    return unless $mode;
    usage_quit "two modes given: --$mode and $_[0]";
}

sub check_types ($)
{
    return unless $type;
    usage_quit "two binary format specifications given: --$type and $_[0]";
}

sub print_binfmt ($$$)
{
    my ($name, $description, $line) = @_;
    if ($line =~ /\n/)
    {
	quit "newlines prohibited in update-binfmts files ($line).";
    }
    if ($test)
    {
	printf "%12s = %s\n", $description, $line;
	push @{$test_installed{$name}}, $line;
    }
    else
    {
	print BINFMT "$line\n";
    }
}

sub rename_mv ($$)
{
    my ($source, $dest) = @_;
    return (rename($source, $dest) || (system('mv', $source, $dest) == 0));
}

sub get_binfmt ($)
{
    my $name = shift;
    if ($test and exists $test_installed{$name})
    {
	return @{$test_installed{$name}};
    }
    my @binfmt;
    open BINFMT, "$admindir/$name"
	or quit "unable to open $admindir/$name: $!";
    push @binfmt, scalar <BINFMT> for 0..5;
    close BINFMT;
    chomp @binfmt;
    return @binfmt;
}

# Loading and unloading logic, which should cope with the various ways this
# has been implemented.

sub get_binfmt_style ()
{
    my $style;
    open FS, '/proc/filesystems'
	or quit "unable to open /proc/filesystems: $!";
    if (grep m/\bbinfmt_misc\b/, <FS>)
    {
	# As of 2.4.3, the official Linux kernel still uses the original
	# interface, but Alan Cox's patches add a binfmt_misc filesystem
	# type which needs to be mounted separately. This may get into the
	# official kernel in the future, so support both.
	$style = 'filesystem';
    }
    else
    {
	# The traditional interface.
	$style = 'procfs';
    }
    close FS;
    return $style;
}

sub load_binfmt_misc ()
{
    unless (-d $procdir)
    {
	if (system qw(/sbin/modprobe binfmt_misc))
	{
	    warning "Couldn't load the binfmt_misc module.";
	    return 0;
	}
	else
	{
	    unless (-d $procdir)
	    {
		warning "binfmt_misc module seemed to load, but no $procdir " .
			"directory! Giving up.";
		return 0;
	    }
	}
    }

    my $style = get_binfmt_style;
    # TODO: Is checking for $register the right way to go here?
    if ($style eq 'filesystem' and not -f $register)
    {
	if (system qw(/bin/mount -t binfmt_misc none), $procdir)
	{
	    warning "Couldn't mount the binfmt_misc filesystem on $procdir.";
	    return 0;
	}
	else
	{
	    unless (-f $register)
	    {
		warning "binfmt_misc filesystem mounted, but $register " .
			"missing! Giving up.";
		return 0;
	    }
	}
    }

    return 1;
}

sub unload_binfmt_misc ()
{
    my $style = get_binfmt_style;
    if ($style eq 'filesystem')
    {
	if (system '/bin/umount', $procdir)
	{
	    warning "Couldn't unmount the binfmt_misc filesystem from " .
		    "$procdir.";
	    return 0;
	}
    }
    if (system qw(/sbin/modprobe -r binfmt_misc))
    {
	warning "Couldn't unload the binfmt_misc module.";
	return 0;
    }
    return 1;
}

# Actions.

# Enable a binary format in the kernel.
sub act_enable (;$);
sub act_enable (;$)
{
    my $name = shift;
    return 0 unless load_binfmt_misc;
    if (defined $name)
    {
	unless ($test or -e "$admindir/$name")
	{
	    warning "$name not in database of installed binary formats.";
	    return 0;
	}
	my ($package, $type, $offset, $magic, $mask, $interpreter) =
	    get_binfmt $name;
	$type = ($type eq 'magic') ? 'M' : 'E';
	my $regstring = ":$name:$type:$offset:$magic:$mask:$interpreter:\n";
	if ($test)
	{
	    print "enable $name with the following format string:\n",
		  " $regstring";
	}
	else
	{
	    open REGISTER, ">$register"
		or warning "unable to open $register for writing: $!",
		   return 0;
	    print REGISTER $regstring;
	    close REGISTER
		or warning "unable to close $register: $!", return 0;
	}
    }
    else
    {
	opendir ADMINDIR, $admindir
	    or warning "unable to open $admindir: $!", return 0;
	while (defined($_ = readdir ADMINDIR))
	{
	    act_enable $_ unless /^\.\.?$/ or -e "$procdir/$_";
	}
	closedir ADMINDIR;
    }
    return 1;
}

# Disable a binary format in the kernel.
sub act_disable (;$);
sub act_disable (;$)
{
    my $name = shift;
    return 1 unless -d $procdir;    # We're disabling anyway, so we don't mind
    if (defined $name)
    {
	unless (-e "$procdir/$name")
	{
	    # Don't warn in this circumstance, as it could happen e.g. when
	    # binfmt-support and a package depending on it are upgraded at
	    # the same time, so we get called when stopped. Just pretend
	    # that the disable operation succeeded.
	    return 1;
	}

	# We used to check the entry in $procdir to make sure we were
	# removing an entry with the same interpreter, but this is bad; it
	# makes things really difficult for packages that want to change
	# their interpreter, for instance. Now we unconditionally remove and
	# rely on the calling logic to check that the entry in $admindir
	# belongs to the same package.
	# 
	# In other words, $admindir becomes the canonical reference, not
	# $procdir. This is in line with similar update-* tools in Debian.

	if ($test)
	{
	    print "disable $name\n";
	}
	else
	{
	    open PROCENTRY, ">$procdir/$name"
		or warning "unable to open $procdir/$name for writing: $!",
		   return 0;
	    print PROCENTRY -1;
	    close PROCENTRY
		or warning "unable to close $procdir/$name: $!", return 0;
	    -e "$procdir/$name"
		and quit "removal of $procdir/$name ignored by kernel!";
	}
    }
    else
    {
	opendir ADMINDIR, $admindir
	    or warning "unable to open $admindir: $!", return 0;
	while (defined($_ = readdir ADMINDIR))
	{
	    act_disable $_ unless /^\.\.?$/ or not -e "$procdir/$_";
	}
	closedir ADMINDIR;
	return 0 unless unload_binfmt_misc;
    }
    return 1;
}

sub act_install ($)
{
    my $name = shift;
    if (-f "$admindir/$name")
    {
	# For now we just silently zap any old versions with the same
	# package name (has to be silent or upgrades are annoying). Maybe we
	# should be more careful in the future.
	my $oldpackage = (get_binfmt $name)[0];
	unless ($package eq $oldpackage)
	{
	    $package = '<local>'	    if $package eq ':';
	    $oldpackage = '<local>'	    if $oldpackage eq ':';
	    quit "current package is $package, but binary format already " .
		 "installed by $oldpackage.";
	}
	act_disable $name or quit "unable to disable binary format $name.";
    }
    if (-e "$procdir/$name" and not $test)
    {
	# This is a bit tricky. If we get here, then the kernel knows about
	# a format we don't. Either somebody has used binfmt_misc directly,
	# or update-binfmts did something wrong. For now we do nothing;
	# disabling and re-enabling all binary formats will fix this anyway.
	# There may be a --force option in the future to help with problems
	# like this.
	# 
	# Disabled for --test, because otherwise it never works; the
	# vagaries of binfmt_misc mean that it isn't really possible to find
	# out from userspace exactly what's going to happen if people have
	# been bypassing update-binfmts.
	quit "found manually created entry for $name in $procdir; " .
	     "leaving it alone.";
    }
    if ($test)
    {
	print "install the following binary format description:\n";
    }
    else
    {
	unlink "$admindir/$name.tmp" or $! == ENOENT
	    or quit "unable to ensure $admindir/$name.tmp nonexistent: $!";
	open BINFMT, ">$admindir/$name.tmp"
	    or quit "unable to open $admindir/$name.tmp for writing: $!";
    }
    print_binfmt $name, 'package', $package;
    print_binfmt $name, 'type', $type;
    print_binfmt $name, 'offset', (defined($offset) ? $offset : '');
    print_binfmt $name, 'magic', (defined($magic) ? $magic : $extension);
    print_binfmt $name, 'mask', (defined($mask) ? $mask : '');
    print_binfmt $name, 'interpreter', $interpreter;
    unless ($test)
    {
	close BINFMT or quit "unable to close $admindir/$name.tmp: $!";
	rename_mv "$admindir/$name.tmp", "$admindir/$name"
	    or quit "unable to install $admindir/$name.tmp as " .
		    "$admindir/$name: $!";
    }
    act_enable $name or quit "unable to enable binary format $name.";
}

sub act_remove ($)
{
    my $name = shift;
    unless (-f "$admindir/$name")
    {
	# There may be a --force option in the future to allow entries like
	# this to be removed; either they were created manually or
	# update-binfmts was broken.
	quit "$admindir/$name does not exist; nothing to do!";
    }
    my $oldpackage = (get_binfmt $name)[0];
    unless ($package eq $oldpackage)
    {
	$package = '<local>'	    if $package eq ':';
	$oldpackage = '<local>'	    if $oldpackage eq ':';
	quit "current package is $package, but binary format already " .
	     "installed by $oldpackage.";
    }
    act_disable $name or quit "unable to disable binary format $name.";
    if ($test)
    {
	print "remove $admindir/$name\n";
    }
    else
    {
	unlink "$admindir/$name"
	    or quit "unable to remove $admindir/$name: $!";
    }
}

sub act_display (;$);
sub act_display (;$)
{
    my $name = shift;
    if (defined $name)
    {
	print "$name (", (-e "$procdir/$name" ? 'enabled' : 'disabled'),
	      "):\n";
	my ($package, $type, $offset, $magic, $mask, $interpreter) =
	    get_binfmt $name;
	$package = '<local>' if $package eq ':';
	print <<EOF;
     package = $package
        type = $type
      offset = $offset
       magic = $magic
        mask = $mask
 interpreter = $interpreter
EOF
    }
    else
    {
	opendir ADMINDIR, $admindir or quit "unable to open $admindir: $!";
	while (defined($_ = readdir ADMINDIR))
	{
	    act_display $_ unless /^\.\.?$/;
	}
	closedir ADMINDIR;
    }
}

# Now go.

check_supported_os;

my @modes = qw(install remove display enable disable);
my @types = qw(magic extension);

my %unique_options = (
    'package'	=> \$package,
    'mask'	=> \$mask,
    'offset'	=> \$offset,
);

my %arguments = (
    'admindir'	=> ['path' => \$admindir],
    'install'	=> ['name' => \$name, 'path' => \$interpreter],
    'remove'	=> ['name' => \$name, 'path' => \$interpreter],
    'package'	=> ['package-name' => \$package],
    'magic'	=> ['byte-sequence' => \$magic],
    'extension'	=> ['extension' => \$extension],
    'mask'	=> ['byte-sequence' => \$mask],
    'offset'	=> ['offset' => \$offset],
);

my %parser = (
    'help'	=> sub { usage; exit 0; },
    'version'	=> sub { version; exit 0; },
    'test'	=> sub { $test = 1; },
    'install'	=> sub { -e $interpreter or
			    warning "$interpreter not found, but continuing " .
				    "anyway as you request"; },
    'remove'	=> sub { -e $interpreter or
			    warning "$interpreter not found, but continuing " .
				    "anyway as you request"; },
    'display'	=> sub { $name = (@ARGV >= 1) ? shift @ARGV : undef; },
    'enable'	=> sub { $name = (@ARGV >= 1) ? shift @ARGV : undef; },
    'disable'	=> sub { $name = (@ARGV >= 1) ? shift @ARGV : undef; },
    'offset'	=> sub { $offset =~ /^\d+$/ or
			    usage_quit 'offset must be a whole number'; },
);

while (defined($_ = shift))
{
    last if /^--$/;
    if (!/^--(.+)$/)
    {
	usage_quit "unknown argument '$_'";
    }
    my $option = $1;
    my $is_mode = grep { $_ eq $option } @modes;
    my $is_type = grep { $_ eq $option } @types;
    my $has_args = exists $arguments{$option};

    unless ($is_mode or $is_type or $has_args or exists $parser{$option})
    {
	usage_quit "unknown argument '$_'";
    }

    check_modes $option if $is_mode;
    check_types $option if $is_type;

    if (exists $unique_options{$option} and
	defined ${$unique_options{$option}})
    {
	usage_quit "mode than one --$option option given";
    }

    if ($has_args)
    {
	my (@descs, @varrefs);
	# Split into descriptions and variable references.
	my $alt = 0;
	foreach my $arg (@{$arguments{$option}})
	{
	    if (($alt = !$alt))	{ push @descs, "<$arg>"; }
	    else		{ push @varrefs, $arg; }
	}
	usage_quit "--$option needs @descs" unless @ARGV >= @descs;
	foreach my $varref (@varrefs) { $$varref = shift @ARGV; }
    }

    &{$parser{$option}} if defined $parser{$option};

    $mode = $option if $is_mode;
    $type = $option if $is_type;
}

$package = ':' unless defined $package;

unless (defined $mode)
{
    usage_quit 'you must use one of --install, --remove, --display, ' .
	       '--enable, or --disable';
}

if ($mode eq 'install')
{
    defined $type or usage_quit '--install requires a <spec> option';
    if ($type eq 'extension')
    {
	defined $magic
	    and usage_quit "can't use both --magic and --extension";
	defined $mask	and usage_quit "can't use --mask with --extension";
	defined $offset	and usage_quit "can't use --offset with --extension";
    }
    if ($name =~ /^(\.\.?|register|status)$/)
    {
	usage_quit "binary format name $name is reserved";
    }
}

-d $admindir or quit "unable to open $admindir: $!";

my %actions = (
    'install'	=> \&act_install,
    'remove'	=> \&act_remove,
    'display'	=> \&act_display,
    'enable'	=> \&act_enable,
    'disable'	=> \&act_disable,
);

unless (exists $actions{$mode})
{
    usage_quit "unknown mode: $mode";
}

$actions{$mode}($name);


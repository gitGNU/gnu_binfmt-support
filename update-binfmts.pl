#! /usr/bin/perl -w

# Copyright (c) 2000-2002 Colin Watson <cjwatson@debian.org>.
# See update-binfmts(8) for documentation.

use strict;

use Errno qw(ENOENT);
use POSIX qw(uname);
use Text::Wrap;

my $VERSION = '@VERSION@';

$Text::Wrap::columns = 79;

my $test;
my %test_installed;
my $importdir = '/usr/share/binfmts';
my $admindir = '/var/lib/binfmts';
my $package;
my $mode;
my ($name, $interpreter);
my $type;
my ($magic, $mask, $offset, $extension);

my $procdir = '/proc/sys/fs/binfmt_misc';
my $register = "$procdir/register";

local *BINFMT;

# Various "print something and exit" routines.

sub quit ($;@)
{
    print STDERR wrap '', '', 'update-binfmts:', @_, "\n";
    exit 2;
}

sub version ()
{
    print "update-binfmts $VERSION.\n"
	or quit "unable to write version message: $!";
}

sub usage ()
{
    version;
    print <<EOF
Copyright (c) 2000-2002 Colin Watson. This is free software; see the GNU
General Public License version 2 or later for copying conditions.

Usage:

  update-binfmts [options] --install <name> <path> <spec>
  update-binfmts [options] --remove <name> <path>
  update-binfmts [options] --import [<name>]
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
    --importdir <directory>     use <directory> instead of /usr/share/binfmts
                                as import directory
    --test                      don't do anything, just demonstrate
    --help                      print this help screen and exit
    --version                   output version and exit

EOF
	or quit "unable to write usage message: $!";
}

sub usage_quit ($;@)
{
    print STDERR wrap '', '', 'update-binfmts:', @_, "\n\n";
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
    if ($sysname eq 'GNU') {
	print <<EOF;
Patches for Hurd support are welcomed; they should not be difficult.
EOF
    }
    exit 2;
}

# Something has gone wrong, but not badly enough for us to give up.
sub warning ($;@) {
    print STDERR wrap '', '', 'update-binfmts: warning:', @_, "\n";
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

sub print_binfmt ($%)
{
    my ($name, %binfmt) = @_;
    for (keys %binfmt) {
	if ($binfmt{$_} =~ /\n/) {
	    quit "newlines prohibited in update-binfmts files ($binfmt{$_})";
	}
    }

    my %order = (package => 0, type => 1, offset => 2,
		 magic => 3,   mask => 4, interpreter => 5);
    my $sort_binfmt = sub {
	return $order{$a} <=> $order{$b};
    };

    if ($test) {
	for (sort $sort_binfmt keys %binfmt) {
	    printf "%12s = %s\n", $_, $binfmt{$_};
	}
	%{$test_installed{$name}} = %binfmt;
    } else {
	for (sort $sort_binfmt keys %binfmt) {
	    print BINFMT "$binfmt{$_}\n";
	}
    }
}

sub rename_mv ($$)
{
    my ($source, $dest) = @_;
    return (rename($source, $dest) || (system('mv', $source, $dest) == 0));
}

sub get_import ($)
{
    my $name = shift;
    my %import;
    unless (open IMPORT, "< $name") {
	warning "unable to open $name: $!";
	return;
    }
    local $_;
    while (<IMPORT>) {
	chomp;
	my ($name, $value) = split ' ', $_, 2;
	$import{lc $name} = $value;
    }
    return %import;
}

sub get_binfmt ($)
{
    my $name = shift;
    if ($test and exists $test_installed{$name}) {
	return %{$test_installed{$name}};
    }
    my %binfmt;
    open BINFMT, "$admindir/$name"
	or quit "unable to open $admindir/$name: $!";
    $binfmt{package}     = <BINFMT>;
    $binfmt{type}        = <BINFMT>;
    $binfmt{offset}      = <BINFMT>;
    $binfmt{magic}       = <BINFMT>;
    $binfmt{mask}        = <BINFMT>;
    $binfmt{interpreter} = <BINFMT>;
    close BINFMT;
    chomp $binfmt{$_} for keys %binfmt;
    return %binfmt;
}

# Loading and unloading logic, which should cope with the various ways this
# has been implemented.

sub get_binfmt_style ()
{
    my $style;
    unless (open FS, '/proc/filesystems') {
	# Weird. Assume procfs.
	warning "unable to open /proc/filesystems: $!";
	return 'procfs';
    }
    if (grep m/\bbinfmt_misc\b/, <FS>) {
	# As of 2.4.3, the official Linux kernel still uses the original
	# interface, but Alan Cox's patches add a binfmt_misc filesystem
	# type which needs to be mounted separately. This may get into the
	# official kernel in the future, so support both.
	$style = 'filesystem';
    } else {
	# The traditional interface.
	$style = 'procfs';
    }
    close FS;
    return $style;
}

sub load_binfmt_misc ()
{
    if ($test) {
	print "load binfmt_misc\n";
	return 1;
    }

    unless (-f $register) {
	if (not -x '/sbin/modprobe' or system qw(/sbin/modprobe binfmt_misc)) {
	    warning "Couldn't load the binfmt_misc module.";
	    return 0;
	}
	unless (-d $procdir) {
	    warning "binfmt_misc module seemed to load, but no $procdir",
		    "directory! Giving up.";
	    return 0;
	}
    }

    my $style = get_binfmt_style;
    # TODO: Is checking for $register the right way to go here?
    if ($style eq 'filesystem' and not -f $register) {
	if (system qw(/bin/mount -t binfmt_misc none), $procdir) {
	    warning "Couldn't mount the binfmt_misc filesystem on $procdir.";
	    return 0;
	}
    }

    if (-f $register) {
	return 1;
    } else {
	warning "binfmt_misc initialized, but $register missing! Giving up.";
	return 0;
    }
}

sub unload_binfmt_misc ()
{
    my $style = get_binfmt_style;

    if ($test) {
	print "unload binfmt_misc ($style)\n";
	return 1;
    }

    if ($style eq 'filesystem') {
	if (system '/bin/umount', $procdir) {
	    warning "Couldn't unmount the binfmt_misc filesystem from",
		    "$procdir.";
	    return 0;
	}
    }
    if (not -x '/sbin/modprobe' or system qw(/sbin/modprobe -r binfmt_misc)) {
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
    return 1 unless load_binfmt_misc;
    if (defined $name) {
	unless ($test or -e "$admindir/$name") {
	    warning "$name not in database of installed binary formats.";
	    return 0;
	}
	my %binfmt = get_binfmt $name;
	my $type = ($binfmt{type} eq 'magic') ? 'M' : 'E';
	my $regstring = ":$name:$type:$binfmt{offset}:$binfmt{magic}" .
			":$binfmt{mask}:$binfmt{interpreter}:\n";
	if ($test) {
	    print "enable $name with the following format string:\n",
		  " $regstring";
	} else {
	    unless (open REGISTER, ">$register") {
		warning "unable to open $register for writing: $!";
		return 0;
	    }
	    print REGISTER $regstring;
	    unless (close REGISTER) {
		warning "unable to close $register: $!";
		return 0;
	    }
	}
	return 1;
    } else {
	unless (opendir ADMINDIR, $admindir) {
	    warning "unable to open $admindir: $!";
	    return 0;
	}
	my $worked = 1;
	for (readdir ADMINDIR) {
	    if (-f "$admindir/$_" and not -e "$procdir/$_") {
		$worked &= act_enable $_;
	    }
	}
	closedir ADMINDIR;
	return $worked;
    }
}

# Disable a binary format in the kernel.
sub act_disable (;$);
sub act_disable (;$)
{
    my $name = shift;
    return 1 unless -d $procdir;    # We're disabling anyway, so we don't mind
    if (defined $name) {
	unless (-e "$procdir/$name") {
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

	if ($test) {
	    print "disable $name\n";
	} else {
	    unless (open PROCENTRY, ">$procdir/$name") {
		warning "unable to open $procdir/$name for writing: $!";
		return 0;
	    }
	    print PROCENTRY -1;
	    unless (close PROCENTRY) {
		warning "unable to close $procdir/$name: $!";
		return 0;
	    }
	    if (-e "$procdir/$name") {
		warning "removal of $procdir/$name ignored by kernel!";
		return 0;
	    }
	}
	return 1;
    }
    else
    {
	unless (opendir ADMINDIR, $admindir) {
	    warning "unable to open $admindir: $!";
	    return 0;
	}
	my $worked = 1;
	for (readdir ADMINDIR) {
	    if (-f "$admindir/$_" and -e "$procdir/$_") {
		$worked &= act_disable $_;
	    }
	}
	closedir ADMINDIR;
	unload_binfmt_misc;	# ignore errors here
	return $worked;
    }
}

sub act_install ($)
{
    my $name = shift;
    if (-f "$admindir/$name") {
	# For now we just silently zap any old versions with the same
	# package name (has to be silent or upgrades are annoying). Maybe we
	# should be more careful in the future.
	my %binfmt = get_binfmt $name;
	my $oldpackage = $binfmt{package};
	unless ($package eq $binfmt{package}) {
	    $package = '<local>'	    if $package eq ':';
	    $binfmt{package} = '<local>'    if $binfmt{package} eq ':';
	    warning "current package is $package, but binary format already",
		    "installed by $binfmt{package}";
	    return 0;
	}
	unless (act_disable $name) {
	    warning "unable to disable binary format $name";
	    return 0;
	}
    }
    if (-e "$procdir/$name" and not $test) {
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
	warning "found manually created entry for $name in $procdir;",
		"leaving it alone";
	return 1;
    }
    if ($test) {
	print "install the following binary format description:\n";
    } else {
	unless (unlink "$admindir/$name.tmp") {
	    if ($! != ENOENT) {
		warning "unable to ensure $admindir/$name.tmp nonexistent: $!";
		return 0;
	    }
	}
	unless (open BINFMT, ">$admindir/$name.tmp") {
	    warning "unable to open $admindir/$name.tmp for writing: $!";
	    return 0;
	}
    }
    print_binfmt $name, (package => $package, type => $type,
			 offset  => (defined($offset) ? $offset : ''),
			 magic   => (defined($magic)  ? $magic  : $extension),
			 mask    => (defined($mask)   ? $mask   : ''),
			 interpreter => $interpreter);
    unless ($test) {
	unless (close BINFMT) {
	    warning "unable to close $admindir/$name.tmp: $!";
	    return 0;
	}
	unless (rename_mv "$admindir/$name.tmp", "$admindir/$name") {
	    warning "unable to install $admindir/$name.tmp as",
		    "$admindir/$name: $!";
	    return 0;
	}
    }
    unless (act_enable $name) {
	warning "unable to enable binary format $name";
	return 0;
    }
    return 1;
}

sub act_remove ($)
{
    my $name = shift;
    unless (-f "$admindir/$name") {
	# There may be a --force option in the future to allow entries like
	# this to be removed; either they were created manually or
	# update-binfmts was broken.
	warning "$admindir/$name does not exist; nothing to do!";
	return 0;
    }
    my %binfmt = get_binfmt $name;
    my $oldpackage = $binfmt{package};
    unless ($package eq $oldpackage) {
	$package = '<local>'	    if $package eq ':';
	$oldpackage = '<local>'	    if $oldpackage eq ':';
	warning "current package is $package, but binary format already",
		"installed by $oldpackage; not removing.";
	# I don't think this should be fatal.
	return 1;
    }
    unless (act_disable $name) {
	warning "unable to disable binary format $name";
	return 0;
    }
    if ($test) {
	print "remove $admindir/$name\n";
    } else {
	unless (unlink "$admindir/$name") {
	    warning "unable to remove $admindir/$name: $!";
	    return 0;
	}
    }
    return 1;
}

sub act_import (;$);
sub act_import (;$)
{
    my $name = shift;
    if (defined $name) {
	my $id;
	if ($name =~ m!.*/(.*)!) {
	    $id = $1;
	} else {
	    $id = $name;
	    $name = "$importdir/$name";
	}

	if ($id =~ /^(\.\.?|register|status)$/) {
	    warning "binary format name '$id' is reserved";
	    return 0;
	}

	my %import = get_import $name;
	unless (scalar keys %import) {
	    warning "couldn't find information about '$id' to import";
	    return 0;
	}
	$package     = $import{package};
	$magic       = $import{magic};
	$extension   = $import{extension};
	$mask        = $import{mask};
	$offset      = $import{offset};
	$interpreter = $import{interpreter};

	if (-f "$admindir/$id") {
	    my %binfmt = get_binfmt $id;
	    if ($binfmt{package} eq ':') {
		# Installed version was installed manually, so don't import
		# over it.
		warning "preserving local changes to $id";
		return 1;
	    } else {
		# Installed version was installed by a package, so it should
		# be OK to replace it.
	    }
	}

	# TODO: This duplicates the verification code below.
	unless (defined $package) {
	    warning "$name: required 'package' line missing";
	    return 0;
	}

	if (defined $magic) {
	    if (defined $extension) {
		warning "$name: can't use both 'magic' and 'extension'";
		return 0;
	    } else {
		$type = 'magic';
	    }
	} else {
	    if (defined $extension) {
		$type = 'extension';
	    } else {
		warning "$name: 'magic' or 'extension' line required";
		return 0;
	    }
	}

	if ($type eq 'extension') {
	    if (defined $mask) {
		warning "$name: can't use 'mask' with 'extension'";
		return 0;
	    }
	    if (defined $offset) {
		warning "$name: can't use 'offset' with 'extension'";
		return 0;
	    }
	}

	unless (-e $interpreter) {
	    warning "$name: $interpreter not found, but continuing anyway as ",
		    "you request";
	}

	act_install $id;
	return 1;
    } else {
	unless (opendir IMPORTDIR, $importdir) {
	    warning "unable to open $importdir: $!";
	    return 0;
	}
	my $worked = 1;
	for (readdir IMPORTDIR) {
	    next unless -f "$importdir/$_";
	    if (-f "$importdir/$_") {
		$worked &= act_import $_;
	    }
	}
	closedir IMPORTDIR;
	return $worked;
    }
}

sub act_display (;$);
sub act_display (;$)
{
    my $name = shift;
    if (defined $name) {
	print "$name (", (-e "$procdir/$name" ? 'enabled' : 'disabled'),
	      "):\n";
	my %binfmt = get_binfmt $name;
	my $package = $binfmt{package} eq ':' ? '<local>' : $binfmt{package};
	print <<EOF;
     package = $package
        type = $binfmt{type}
      offset = $binfmt{offset}
       magic = $binfmt{magic}
        mask = $binfmt{mask}
 interpreter = $binfmt{interpreter}
EOF
    } else {
	opendir ADMINDIR, $admindir or quit "unable to open $admindir: $!";
	for (readdir ADMINDIR) {
	    act_display $_ unless /^\.\.?$/;
	}
	closedir ADMINDIR;
    }
    return 1;
}

# Now go.

check_supported_os;

my @modes = qw(install remove import display enable disable);
my @types = qw(magic extension);

my %unique_options = (
    'package'	=> \$package,
    'mask'	=> \$mask,
    'offset'	=> \$offset,
);

my %arguments = (
    'admindir'	=> ['path' => \$admindir],
    'importdir'	=> ['path' => \$importdir],
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
    'install'	=> sub {
	-e $interpreter
	    or warning "$interpreter not found, but continuing anyway as you",
		       "request";
    },
    'remove'	=> sub {
	-e $interpreter
	    or warning "$interpreter not found, but continuing anyway as you",
		       "request";
    },
    'import'	=> sub { $name = (@ARGV >= 1) ? shift @ARGV : undef; },
    'display'	=> sub { $name = (@ARGV >= 1) ? shift @ARGV : undef; },
    'enable'	=> sub { $name = (@ARGV >= 1) ? shift @ARGV : undef; },
    'disable'	=> sub { $name = (@ARGV >= 1) ? shift @ARGV : undef; },
    'offset'	=> sub {
	$offset =~ /^\d+$/
	    or usage_quit 'offset must be a whole number';
    },
);

while (defined($_ = shift))
{
    last if /^--$/;
    if (!/^--(.+)$/) {
	usage_quit "unknown argument '$_'";
    }
    my $option = $1;
    my $is_mode = grep { $_ eq $option } @modes;
    my $is_type = grep { $_ eq $option } @types;
    my $has_args = exists $arguments{$option};

    unless ($is_mode or $is_type or $has_args or exists $parser{$option}) {
	usage_quit "unknown argument '$_'";
    }

    check_modes $option if $is_mode;
    check_types $option if $is_type;

    if (exists $unique_options{$option} and
	defined ${$unique_options{$option}}) {
	usage_quit "mode than one --$option option given";
    }

    if ($has_args) {
	my (@descs, @varrefs);
	# Split into descriptions and variable references.
	my $alt = 0;
	foreach my $arg (@{$arguments{$option}}) {
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

unless (defined $mode) {
    usage_quit 'you must use one of --install, --remove, --import, --display,',
	       '--enable, --disable';
}

if ($mode eq 'install') {
    defined $type or usage_quit '--install requires a <spec> option';
    if ($type eq 'extension') {
	defined $magic
	    and usage_quit "can't use both --magic and --extension";
	defined $mask	and usage_quit "can't use --mask with --extension";
	defined $offset	and usage_quit "can't use --offset with --extension";
    }
    if ($name =~ /^(\.\.?|register|status)$/) {
	usage_quit "binary format name '$name' is reserved";
    }
}

unless (-d $admindir) {
    quit "unable to open $admindir: $!";
}

my %actions = (
    'install'	=> \&act_install,
    'remove'	=> \&act_remove,
    'import'	=> \&act_import,
    'display'	=> \&act_display,
    'enable'	=> \&act_enable,
    'disable'	=> \&act_disable,
);

unless (exists $actions{$mode}) {
    usage_quit "unknown mode: $mode";
}

if ($actions{$mode}($name)) {
    exit 0;
} else {
    quit 'exiting due to previous errors';
}

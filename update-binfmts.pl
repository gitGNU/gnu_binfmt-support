#! /usr/bin/perl -w

# Copyright (c) 2000 Colin Watson <cjw44@flatline.org.uk>.
# See update-binfmts(8) for documentation.

use strict;

sub ENOENT () { 2; }

my $VERSION = '1.0.3';

my $errstarted = 0;
my $test;
my $admindir = '/var/lib/binfmts';
my $package;
my $mode;
my ($name, $interpreter);
my $type;
my ($magic, $mask, $offset, $extension);

local *BINFMT;

sub wrap ($)
{
    my $text = shift;
    $text =~ s/^(.{0,79})\s/$1\n/gm;
    return $text;
}

sub quit ($;@)
{
    unless ($errstarted) { print STDERR "\n"; $errstarted = 1; }
    print STDERR wrap "update-binfmts: @_\n";
    exit 2;
}

sub version ()
{
    print "Debian GNU/Linux update-binfmts $VERSION.\n"
	or quit "unable to write version message: $!";
}

sub usage ()
{
    version;
    print <<EOF
Copyright (c) 2000 Colin Watson. This is free software; see the GNU
General Public License version 2 or later for copying conditions.

Usage:

  update-binfmts [options] --install <name> <path> <spec>
  update-binfmts [options] --remove <name> <path>
  update-binfmts [options] --display <name>
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

sub warning ($;@) {
    unless ($errstarted) { print STDERR "\n"; $errstarted = 1; }
    print STDERR wrap "update-binfmts: warning: @_\n";
}

sub check_modes ()
{
    return unless $mode;
    usage_quit "two modes given: --$mode and $_";
}

sub check_types ()
{
    return unless $type;
    usage_quit "two binary format specifications given: --$type and $_";
}

sub print_binfmt ($)
{
    my $line = shift;
    if ($line =~ /\n/)
    {
	quit "newlines prohibited in update-binfmts files ($line).";
    }
    print BINFMT "$line\n";
}

sub rename_mv ($$)
{
    my ($source, $dest) = @_;
    return (rename($source, $dest) || (system('mv', $source, $dest) == 0));
}

sub get_binfmt ($)
{
    my $name = shift;
    my @binfmt;
    open BINFMT, "$admindir/$name"
	or quit "unable to open $admindir/$name: $!";
    push @binfmt, scalar <BINFMT> for 0..5;
    close BINFMT;
    chomp @binfmt;
    return @binfmt;
}

my $procdir = '/proc/sys/fs/binfmt_misc';
my $register = "$procdir/register";

sub enable (;$);
sub enable (;$)
{
    my $name = shift;
    unless (-d $procdir)
    {
	if (system('/sbin/modprobe', 'binfmt_misc'))
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
    if (defined $name)
    {
	unless (-e "$admindir/$name")
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
	    print "\nenable $name with format string:\n$regstring\n";
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
	    enable $_ unless /^\.\.?$/ || -e "$procdir/$_";
	}
	closedir ADMINDIR;
    }
    return 1;
}

sub disable (;$);
sub disable (;$)
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
	    print "\ndisable $name\n";
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
	    disable $_ unless /^\.\.?$/;
	}
	closedir ADMINDIR;
    }
    return 1;
}

while (defined($_ = shift))
{
    last if /^--$/;
    if (!/^--/)		    { usage_quit "unknown argument \'$_'"; }
    elsif (/^--help$/)	    { usage; exit 0; }
    elsif (/^--version$/)   { version; exit 0; }
    elsif (/^--test$/)	    { $test = 1; }
    elsif (/^--admindir$/)
    {
	usage_quit "--admindir needs <path>" unless @ARGV >= 1;
	$admindir = shift;
    }

    # Main modes of operation.
    elsif (/^--(install|remove)$/)
    {
	check_modes;
	usage_quit "--$1 needs <name> <path>" unless @ARGV >= 2;
	$name = shift;
	$interpreter = shift;
	-e $interpreter or
	    warning "$interpreter not found, but continuing anyway as you " .
		    "request";
	$mode = $1;
    }
    elsif (/^--display$/)
    {
	check_modes;
	usage_quit '--display needs <name>' unless @ARGV >= 1;
	$name = shift;
	$mode = 'display';
    }
    elsif (/^--(enable|disable)$/)
    {
	check_modes;
	$name = (@ARGV >= 1) ? shift : undef;
	$mode = $1;
    }

    # Package name.
    elsif (/^--package$/)
    {
	usage_quit 'more than one --package option given' if defined $package;
	usage_quit '--package needs <package-name>' unless @ARGV >= 1;
	$package = shift;
    }

    # Binary format specifications.
    elsif (/^--magic$/)
    {
	check_types;
	usage_quit '--magic needs <byte-sequence>' unless @ARGV >= 1;
	$magic = shift;
	$type = 'magic';
    }
    elsif (/^--extension$/)
    {
	check_types;
	usage_quit '--extension needs <extension>' unless @ARGV >= 1;
	$extension = shift;
	$type = 'extension';
    }

    # --magic options.
    elsif (/^--mask$/)
    {
	usage_quit 'more than one --mask option given' if defined $mask;
	usage_quit '--mask needs <byte-sequence>' unless @ARGV >= 1;
	$mask = shift;
    }
    elsif (/^--offset$/)
    {
	usage_quit 'more than one --offset option given' if defined $offset;
	usage_quit '--offset needs <offset>' unless @ARGV >= 1;
	$offset = shift;
	$offset =~ /^\d+$/ or usage_quit 'offset must be a whole number';
    }

    else { usage_quit "unknown argument \'$_'"; }
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

if ($mode eq 'install')
{
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
	disable $name or quit "unable to disable binary format $name.";
    }
    if (-e "$procdir/$name")
    {
	# This is a bit tricky. If we get here, then the kernel knows about
	# a format we don't. Either somebody has used binfmt_misc directly,
	# or update-binfmts did something wrong. For now we do nothing;
	# disabling and re-enabling all binary formats will fix this anyway.
	# There may be a --force option in the future to help with problems
	# like this.
	quit "found manually created entry for $name in $procdir; " .
	     "leaving it alone.";
    }
    if ($test)
    {
	print "installing the following binary format description:\n";
	open BINFMT, '>&1' or quit "unable to dup standard output: $!";
    }
    else
    {
	unlink "$admindir/$name.tmp" or $! == ENOENT
	    or quit "unable to ensure $admindir/$name.tmp nonexistent: $!";
	open BINFMT, ">$admindir/$name.tmp"
	    or quit "unable to open $admindir/$name.tmp for writing: $!";
    }
    print_binfmt $package;
    print_binfmt $type;
    print_binfmt (defined($offset) ? $offset : '');
    print_binfmt (defined($magic) ? $magic : $extension);
    print_binfmt (defined($mask) ? $mask : '');
    print_binfmt $interpreter;
    if ($test)
    {
	close BINFMT or quit "unable to close duplicated standard output: $!";
    }
    else
    {
	close BINFMT or quit "unable to close $admindir/$name.tmp: $!";
	rename_mv "$admindir/$name.tmp", "$admindir/$name"
	    or quit "unable to install $admindir/$name.tmp as " .
		    "$admindir/$name: $!";
    }
    enable $name or quit "unable to enable binary format $name.";
}

elsif ($mode eq 'remove')
{
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
    disable $name or quit "unable to disable binary format $name.";
    if ($test)
    {
	print "removing $admindir/$name\n";
    }
    else
    {
	unlink "$admindir/$name"
	    or quit "unable to remove $admindir/$name: $!";
    }
}

elsif ($mode eq 'display')
{
    open BINFMT, "$admindir/$name"
	or quit "$name binary format not installed.";
    local $/ = undef;
    print <BINFMT>;
    close BINFMT;
}

elsif ($mode eq 'enable')	{ enable $name; }
elsif ($mode eq 'disable')	{ disable $name; }


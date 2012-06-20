# Perl module for Rancid (http://www.shrubbery.net/rancid/)
# Reads and writes Rancid configuration and provides lists of device
# configuration files.

package NMS::Rancid::Cvs;

use strict;
use warnings;
use Carp;
use FileHandle;
use POSIX qw(strftime);

sub new {
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my %args = @_;
    my $self = {};
    $self->{path}    = $args{path} || '/home/rancid';
    $self->{cvsroot} = $args{cvsroot} || '/opt/rancid/var/CVS';
    $self->{debug}   = $args{debug}   || 0;
    $self->{rancid} = $args{rancid} || croak("No reference to rancid object");
    bless $self, $class;
    return undef unless $self->_init();
    return $self;
}

sub cvsroot {
    my $self = shift;
    return $self->{cvsroot};
}

sub path {
    my $self = shift;
    return $self->{path};
}

sub debug {
    my $self = shift;
    return $self->{debug};
}

sub add {
    my $self = shift;
    my $file = shift;
    my $cmd;
    my $arg;
    my $path = $self->path();

    if ($file =~ /$path\/(.+)/) {
        $arg = $1;
    } else {
        croak("File $file not in cvs repo (.".$self->path().")");
    }

    $cmd = $self->_cmd('add');
    $cmd.= $arg;

    # _doCmd returns command error code on errors
    if ($self->_doCmd($cmd)) {
        return undef;
    }
    return 1;
}

sub delete {
    my $self = shift;
    my $file = shift;
    my $cmd;
    my $arg;
    my $path = $self->path();

    if ($file =~ /$path\/(.+)/) {
        $arg = $1;
    } else {
        croak("File $file not in cvs repo (.".$self->path().")");
    }

    $cmd = $self->_cmd('delete');
    $cmd.= $arg;

    # _doCmd returns command error code on errors
    if ($self->_doCmd($cmd)) {
        return undef;
    }
    return 1;
}

sub commit {
    my $self = shift;
    my $file = shift;
    my $message = shift || '';
    my $cmd;
    my $arg;
    my $path = $self->path();
    my $dir;

    if ($file =~ /$path\/(.+)/) {
        $arg = $1;
    } else {
        croak("File $file not in cvs repo (.".$self->path().")");
    }

    # commit must be run in sub-directory
    if ($arg =~ s/(.+?)\///) {
        $dir = $1;
    } else {
        $dir = $arg;
        $arg = "";
    }

    # prepend commit message
    $arg = "-m \"$message\" $arg";

    $cmd = $self->_cmd('commit');
    $cmd =~ s/^cd.+?;/cd $path\/$dir;/;
    $cmd.= $arg;

    # _doCmd returns command error code on errors
    if ($self->_doCmd($cmd)) {
        return undef;
    }
    return 1;
}

sub update {
    my $self = shift;
    my $file = shift;
    my $cmd;
    my $arg;
    my $path = $self->path();
    my $dir;

    if ($file =~ /$path\/(.+)/) {
        $arg = $1;
    } else {
        croak("File $file not in cvs repo (.".$self->path().")");
    }

    # update must be run in sub-directory
    if ($arg =~ s/(.+?)\///) {
        $dir = $1;
    } else {
        $dir = $arg;
        $arg = "";
    }

    $cmd = $self->_cmd('update');
    $cmd =~ s/^cd.+?;/cd $path\/$dir;/;
    $cmd.= $arg;

    # _doCmd returns command error code on errors
    if ($self->_doCmd($cmd)) {
        return undef;
    }
    return 1;
}

# alias for update
sub up {
    my $self = shift;
    return $self->update(@_);
}

sub checkout {
    my $self = shift;
    my $file = shift;
    my $cmd;
    my $arg;
    my $path = $self->path();

    if ($file =~ /$path\/(.+)/) {
        $arg = $1;
    } else {
        croak("File $file not in cvs repo (.".$self->path().")");
    }

    $cmd = $self->_cmd('checkout');
    $cmd.= $arg;

    # _doCmd returns command error code on errors
    if ($self->_doCmd($cmd)) {
        return undef;
    }
    return 1;
}

# alias for checkout
sub co {
    my $self = shift;
    return $self->checkout(@_);
}

sub cvsImport {
    my $self = shift;
    my $file = shift;
    my $message = shift || '';
    my $cmd;
    my $arg;
    my $path = $self->path();

    $message = "-m \"$message\" ";
    if ($file =~ /$path\/(.+)/) {
        $arg = $1;
    } else {
        croak("File $file not in cvs repo (.".$self->path().")");
    }
    croak("Argument must be folder in root of CVS ($arg)") if ($arg =~ /\//);

    $arg = $message.$arg;
    $arg.= ' NMS-Rancid new'; # vendor release paramaters

    $cmd = $self->_cmd('import');
    $cmd =~ s/^cd.+?;/cd $file;/;
    $cmd.= $arg;

    # _doCmd returns command error code on errors
    if ($self->_doCmd($cmd)) {
        return undef;
    }
    return 1;
}

sub diff {
    my $self = shift;
    my $file = shift;
    my ($rev_args) = shift || undef;
    my $cmd;
    my $arg = '-U 2 ';
    my @output;
    my $diff = '';
    my $path = $self->path();

    print "File to diff: $file\n" if $self->debug();

    # process revision arguments
    if ($rev_args) {
        if (defined $rev_args->{time_old}) {
            $rev_args->{time_old} = strftime("%a, %d %b %Y %H:%M:%S %z", localtime($rev_args->{time_old}));
            $arg .= ' -D "'.$rev_args->{time_old}.'" ';
        }
        if (defined $rev_args->{rev_old}) {
            $arg .= ' -r "'.$rev_args->{rev_old}.'" ';
        }
        if (defined $rev_args->{time_new}) {
            $rev_args->{time_new} = strftime("%a, %d %b %Y %H:%M:%S %z", localtime($rev_args->{time_new}));
            $arg .= ' -D "'.$rev_args->{time_new}.'" ';
        }
        if (defined $rev_args->{rev_new}) {
            $arg .= ' -r "'.$rev_args->{rev_new}.'" ';
        }
    }

    if ($file =~ /$path\/(.+)/) {
        $arg.= $1;
    } else {
        croak("File $file not in cvs repo (.".$self->path().")");
    }
    $cmd = $self->_cmd('diff');
    $cmd.= $arg;

    my $ret = $self->_doCmd($cmd, \@output);

    print "cvs diff return code: $ret\n" if $self->debug;

    # cvs diff exit status: 0 - no change, 1 - changes, >1 - error
    return undef if ($ret > 1);
    # HACK remove the last error which contains output of diff
    pop(@NMS::Rancid::errors) if $ret == 1;

    if (scalar @output < 1) { # no changes
        return '';
    }

    $diff = join('', @output);
    return $diff;
}


sub rancid {
    my $self = shift;
    return ${$self->{rancid}};
}


sub _init {
    my $self = shift;

    if (! -d $self->{cvsroot}) {
        $self->rancid()->_pushError("CVS root does not exist (".$self->{cvsroot}.")");
        return undef;
    }
    if (! -d $self->{path}) {
        $self->rancid()->_pushError("CVS local copy does not exist (".$self->{path}.")");
        return undef;
    }
    if ($self->{cvsroot} !~ /^\//) {
        $self->rancid()->_pushError("CVS root path not absolute (".$self->{path}.")");
        return undef;
    }
    if ($self->{path} !~ /^\//) {
        $self->rancid()->_pushError("CVS local copy path not absolute (".$self->{path}.")");
        return undef;
    }

    # remove trailing slashes
    $self->{path}    =~ s/\/*$//;
    $self->{cvsroot} =~ s/\/*$//;

    return 1;
}

# construct command
sub _cmd {
    my $self = shift;
    my $cmd = shift;
    my $debug = $self->debug();
    my $cvs_cmd;

    # prepare cvs command
    $cvs_cmd = 'cd '.$self->path().'; cvs -d '.$self->cvsroot().' ';
    $cvs_cmd.= '-Q ' if (!$debug);
    $cvs_cmd.= $cmd.' ';
    return $cvs_cmd;
}

# run command
sub _doCmd {
    my $self = shift;
    my $cmd = shift;
    my $out_ref = shift || undef;
    my @output;
    my $return = 0;
    my $old_umask = umask 0007;

    $cmd ='umask 0007; '.$cmd; # set umask
    $cmd = $cmd.' 2>&1';       # capture stderr also
    print "$cmd\n" if $self->debug();

    @output = `$cmd`;
    umask $old_umask;
    $return = $? >> 8;
    print "cmd exit code: $return\n" if $self->debug;

    if ($return != 0) {
        $self->rancid()->_pushError(join('', @output));
    }
    print join('', @output) if $self->debug();

    if (ref $out_ref) {
        push (@{$out_ref}, @output);
    }
    return $return;
}

1;

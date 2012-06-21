# Perl module for Rancid (http://www.shrubbery.net/rancid/)
# Reads and writes Rancid configuration and provides lists of device
# configuration files.

package NMS::Rancid::Node;

use strict;
use warnings;
use Carp;
use File::Copy;

use base qw( NMS::Rancid );

use NMS::Rancid::Cvs;

sub new {
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my %args = @_;
    my $self = {};
    $self->{name}  = $args{name} || croak("Node name not defined");
    $self->{group} = $args{group} || croak("Node group not defined");
    $self->{vendor} = undef;
    $self->{status} = undef;
    bless $self, $class;

    $self->_init;

    return $self;
}

sub toString {
    my $self = shift;
    return $self->name;
}

sub name {
    my $self = shift;
    return $self->{name};
}

sub vendor {
    my $self = shift;
    return $self->{vendor};
}

sub status {
    my $self = shift;
    return $self->{status};
}

sub modify {
    my $self = shift;
    my ($args) = @_;
    my $result = {};

    if (defined $args->{status}) {
        $result->{status} = $self->setStatus($args->{status});
        return undef if ! defined $result->{status};
    }
    if (defined $args->{model} || defined $args->{vendor}) {
        $result->{vendor} = $self->setVendor($args);
        return undef if ! defined $result->{vendor};
    }
    return $result;
}

sub setVendor {
    my $self = shift;
    my ($args) = @_;
    my $new_vendor;

    # input validation
    if (!defined $args->{vendor} && ! defined $args->{model}) {
        $self->rancid->_pushError(
            sprintf("Cannot change vendor (%s -> ??). Missing value for new vendor.",
                $self->{vendor})
        );
        return undef;
    }
    elsif (defined $args->{vendor}) {
        $new_vendor = $args->{vendor};
    }
    elsif (defined $args->{model}) {
        $new_vendor = $self->rancid->getVendorFromModel($args->{model});
    }

    if ($new_vendor eq $self->{vendor}) {
        return $self->{vendor};
    }

    # modify vendor property
    my $name = $self->name();
    if (!defined $self->rancid()->{supported_vendors}->{$new_vendor}) {
        $self->rancid->_pushError(
            sprintf("Cannot change vendor (%s -> %s). Vendor %s not supported",
                $self->{vendor}, $new_vendor, $new_vendor)
        );
        return undef;
    }

    # modify rotuer.db of group
    my $router_db = $self->group->storagePath.'/'.'router.db';
    if (!-f $router_db) {
        $self->rancid->_pushError(
            sprintf("Cannot change vendor (%s -> %s). Cannot find router.db at %s",
                $self->{vendor}, $new_vendor, $router_db)
        );
        return undef;
    }
    open DB, "<$router_db" or do {
        $self->rancid->_pushError(
            sprintf("Cannot change vendor (%s -> %s). Cannot open %s for reading.",
                $self->{vendor}, $new_vendor, $router_db)
        );
        return undef;
    };
    my @db_lines = <DB>;
    close DB;
    @db_lines = map { s/^(\s*$name):.+:/$1:$new_vendor:/; $_ } @db_lines;
    open DB, ">$router_db" or do {
        $self->rancid->_pushError(
            sprintf("Cannot change vendor (%s -> %s). Cannot open %s for writing.",
                $self->{vendor}, $new_vendor, $router_db)
        );
        return undef;
    };
    print DB @db_lines;
    close DB;

    # take care of cvs commits
    return undef unless ${$self->rancid()->{cvs}}->commit($self->group->storagePath, "modified vendor of $name");
    return undef unless $self->rancid()->_cvsUpdate($self->group->storagePath);

    # set new vendor
    $self->{vendor} = $new_vendor;

    return $self->{vendor};
}

sub setStatus {
    my $self = shift;
    my $new_status = shift;
    my $name = $self->name;

    # input validation
    if (!defined $new_status) {
        $self->rancid->_pushError(
            sprintf("Cannot change status (%s -> ??). Invalid value for new status.",
                $self->{status})
        );
        return undef;
    }

    if ($new_status eq $self->{status}) {
        return $self->{status};
    }

    # modify rotuer.db of group
    my $router_db = $self->group->storagePath.'/'.'router.db';
    if (!-f $router_db) {
        $self->rancid->_pushError(
            sprintf("Cannot change status (%s -> %s). Cannot find router.db at %s",
                $self->{status}, $new_status, $router_db)
        );
        return undef;
    }
    open DB, "<$router_db" or do {
        $self->rancid->_pushError(
            sprintf("Cannot change status (%s -> %s). Cannot open %s for reading.",
                $self->{status}, $new_status, $router_db)
        );
        return undef;
    };
    my @db_lines = <DB>;
    close DB;
    @db_lines = map { s/^(\s*$name:.+):.+$/$1:$new_status/; $_ } @db_lines;
    open DB, ">$router_db" or do {
        $self->rancid->_pushError(
            sprintf("Cannot change status (%s -> %s). Cannot open %s for writing.",
                $self->{status}, $new_status, $router_db)
        );
        return undef;
    };
    print DB @db_lines;
    close DB;

    # take care of cvs commits
    return undef unless ${$self->rancid()->{cvs}}->commit($self->group->storagePath, "modified status of $name");
    return undef unless $self->rancid()->_cvsUpdate($self->group->storagePath);

    # set new status
    $self->{status} = $new_status;

    return $self->{status};
}

sub group {
    my $self = shift;
    return ${$self->{group}};
}

sub rancid {
    my $self = shift;
    return ${${$self->{group}}->{rancid}};
}

sub configPath {
    my $self = shift;
    return $self->{config_path};
}

# returns device configuration with secret data replaced by password server
# pointers
sub getConfigText {
    my $self = shift;
    my $config_path = $self->configPath();
    my $config_fh;
    
    if ( ! -f $config_path ) {
        $self->rancid()->_pushError("Config file [$config_path] for device does not exist.");
        return undef;
    }
    
    if ( ! open $config_fh, $config_path ) {
        $self->rancid()->_pushError("Could not open config file [$config_path] ($!).");
        return undef;
    }
    
    return join("", <$config_fh>);
}

# take device configuration text from user, pipe it through rancid filters
# and store it as next config revision
sub addConfigText {
    my $self = shift;
    my ($args) = @_;
    my $vendor = $self->vendor();
    my $tmp_dir = $self->rancid()->{conf}->{TMPDIR};
    my $name = $self->name();
    my $rancid_bin;
    my $rancid_cmd;
    my $ret;
    my $debug = $self->rancid()->{debug};

    if (! defined $args->{text}) {
        $self->rancid()->_pushError("Missing text argument");
        return undef;
    }
    my $text = $args->{text};
    my $commit_message = $args->{message} || "NMS::Rancid";

    # determine the right script to pipe config through
    $rancid_bin = $self->rancid()->{supported_vendors}->{$vendor};
    $rancid_bin = $self->rancid()->{bin_path}.'/'.$rancid_bin;
    unless ($rancid_bin) {
        $self->rancid()->_pushError("Vendor $vendor not supported.");
        return undef;
    }
    unless(-x $rancid_bin) {
        $self->rancid()->_pushError("$rancid_bin not executable");
        return undef;
    }

    # modify config text so it can be parsed by rancid script
    $self->_modifyConfigText(\$text);
    return undef if ($self->rancid->isError());

    # put raw text to temp file
    open TMP, ">", $tmp_dir.'/'.$name or do {
        $self->rancid()->_pushError("Could open temp file for writing ($tmp_dir/$name)");
        return undef;
    };
    print TMP $text;
    close TMP;

    # need to reset ENV variables from rancid config
    my %env_pre = %ENV;
    $self->rancid->_prepareEnvironment();

    # run any password saving code (init)
    if (-f $ENV{SAVE_PWDS_SCRIPT}) {
        require $ENV{SAVE_PWDS_SCRIPT};
        pwdsRancidStart() || do {
            $self->rancid->_pushError(pwdsGetError());
            # set ENV variables back
            %ENV = %env_pre;
            return undef;
        };
    }

    # pipe through appropriate rancid filters
    $rancid_cmd = "cd $tmp_dir; $rancid_bin ";
    # we'll miss some commands so we need to pass debug
    # flag to prevent deleting .new file
    $rancid_cmd.= "-d ";
    $rancid_cmd.= "-f $name ";
    $rancid_cmd.= ">/dev/null 2>&1" if (!$debug);
    carp("'$rancid_cmd'") if ($debug);
    $ret = system($rancid_cmd);

    # run any password saving code (post)
    if (-f $ENV{SAVE_PWDS_SCRIPT}) {
        pwdsRancidEnd() || do {
            $self->rancid->_pushError(pwdsGetError());
            # set ENV variables back
            %ENV = %env_pre;
            return undef;
        };
    }

    # set ENV variables back
    %ENV = %env_pre;

    # did we win?
    if (!$debug) {
        unlink($tmp_dir.'/'.$name) ||
            croak("Could not delete temp file ($tmp_dir/$name)");
    }
    $name.= '.new';
    croak("Filtered config not found ($tmp_dir/$name)")
        if (! -f $tmp_dir.'/'.$name);
    if($ret) {
        croak("Error running '$rancid_cmd': $ret");
        if (!$debug) {
            unlink($tmp_dir.'/'.$name) ||
                croak("Could not delete temp file ($tmp_dir/$name)"); }
    }

    # move filtered config to local cvs repo
    copy($tmp_dir.'/'.$name, $self->configPath()) ||
        croak("Could not copy $name to ".$self->configPath());
    if (!$debug) {
        unlink($tmp_dir.'/'.$name) ||
            croak("Could not delete temp file ($tmp_dir/$name)"); }

    my $diff = $self->rancid()->_cvsDiff($self->configPath(), $self->group->{mailrcpt});
    return undef unless defined $diff;

    return undef unless ${$self->rancid()->{cvs}}->commit($self->group()->storagePath(), $commit_message);
    return undef unless $self->rancid()->_cvsUpdate($self->group()->storagePath());

    return $diff;
}

# use *rancid to save configuration from device
# return diff (if any)
sub saveConfigText {
    my $self = shift;
    my $vendor = $self->vendor();
    my $tmp_dir = $self->rancid()->{conf}->{TMPDIR};
    my $rancid_bin;
    my $rancid_cmd;
    my $ret;
    my $debug = $self->rancid()->{debug};

    my $commit_message = "Saved from live device by NMS::Rancid"; # TODO accept as argument

    # determine the right *rancid script to run
    $rancid_bin = $self->rancid()->{supported_vendors}->{$vendor};
    $rancid_bin = $self->rancid()->{bin_path}.'/'.$rancid_bin;
    unless ($rancid_bin) {
        $self->rancid()->_pushError("Vendor $vendor not supported.");
        return undef;
    }
    unless(-x $rancid_bin) {
        $self->rancid()->_pushError("$rancid_bin not executable");
        return undef;
    }

    # need to reset ENV variables from rancid config
    my %env_pre = %ENV;
    $self->rancid->_prepareEnvironment();
    $ENV{CLOGINRC} = $self->rancid->{cloginrc};

    # run any password saving code (init)
    if (-f $ENV{SAVE_PWDS_SCRIPT}) {
        require $ENV{SAVE_PWDS_SCRIPT};
        pwdsRancidStart() || do {
            $self->rancid->_pushError(pwdsGetError());
            # set ENV variables back
            %ENV = %env_pre;
            return undef;
        };
    }

    # run appropriate *rancid script
    $rancid_cmd = "cd $tmp_dir; $rancid_bin ";
    $rancid_cmd.= $self->name;
    $rancid_cmd.= " 2>&1"; # capture stderr
    carp("'$rancid_cmd'") if ($debug);
    my $cmd_output = qx($rancid_cmd);
    $ret = $?;
    carp("cmd exit code: $ret") if ($debug);
    carp("cmd ouptut: $cmd_output") if ($debug);
    my $config_path = $tmp_dir.'/'.$self->name.'.new'; # this is where out saved config waits

    # run any password saving code (post)
    if (-f $ENV{SAVE_PWDS_SCRIPT}) {
        pwdsRancidEnd() || do {
            $self->rancid->_pushError(pwdsGetError());
            # set ENV variables back
            %ENV = %env_pre;
            return undef;
        };
    }

    # set ENV variables back
    %ENV = %env_pre;
    delete $ENV{CLOGINRC};

    # try to determine if command succedded
    if($ret) {
        $self->rancid->_pushError("Error running '$rancid_cmd': $ret");
        unlink $config_path;
        return undef;
    }
    # if all went fine, there should be no command output
    if (length($cmd_output) > 0) {
        # analize output
        my $err_msg = "";
        if ($cmd_output =~ / \w+login error: (.*)/) {
            $err_msg = $1;
        }
        else {
            $err_msg = $cmd_output;
        }
        $self->rancid->_pushError($err_msg);
        unlink $config_path;
        return undef;
    }
    if (! -f $config_path) {
        $self->rancid->_pushError("Filtered config not found ($config_path)");
        unlink $config_path;
        return undef;
    }

    # *rancid seems to have succedded, add config to repo
    copy($config_path, $self->configPath()) || do {
        $self->rancid->_pushError("Could not copy $config_path to ".$self->configPath());
        unlink $config_path;
        return undef;
    };

    my $diff = $self->rancid()->_cvsDiff($self->configPath(), $self->group->{mailrcpt});
    return undef unless defined $diff;

    return undef unless ${$self->rancid()->{cvs}}->commit($self->group()->storagePath(), $commit_message);
    return undef unless $self->rancid()->_cvsUpdate($self->group()->storagePath());

    return 1 if $diff eq '';
    return $diff;
}

sub _init {
    my $self = shift;
    my $db = $self->group->storagePath.'/router.db';
    my $name = $self->name;

    $self->{config_path} = $self->group->storagePath.'/configs/'.$name;

    open(DB, $db) or croak("Could not open router.db: $db");
    while (<DB>) {
        chomp;
        next if /^\s*[#;]/;
        next if /^\s*$/;
        if (/^$name:(.+):(.+)/) {
            $self->{vendor} = $1;
            $self->{status} = $2;
            close DB;
            return 1;
        }
    }
    close DB;
    return undef;
}


# detect format of text and modify it so it can be parsed
# by apripriate rancid script
sub _modifyConfigText {
    my $self = shift;
    my $textref = shift;
    my $name = $self->name();
    my $vendor = $self->vendor();

    if (length($$textref)<50) {
        $self->_pushError("Config text seems incomplete (too short).");
        return;
    }

    # detect input text format
    my $text_start = substr($$textref, 0, 150);
    if ($vendor eq 'cisco') {
        # see if a prompt appears at start of config text
        if ($text_start !~ /\W$name\s*#/) {
            # text needs modifying
            $$textref = $name."# show running-config\n".$$textref."\n".$name."# exit\n";
        }
    } elsif ($vendor eq 'dell') {
        if ($text_start !~ /\W$name\s*#/) {
            $$textref = $name."# show running-config\n".$$textref."\n".$name."# exit\n";
        }
    } elsif ($vendor eq 'juniper') {
        if ($text_start !~ /$name\S*>/) {
            $$textref = $name."> show configuration\n".$$textref."\n".$name."> quit\n";
        }
    } else {
        # vendor not supported yet
        # give a warrning to user and try out luck with unmodified config
        $self->rancid->_pushError("Config text modification for vendor $vendor not yet supported.");
    }
}

1;

__END__


=head1 NAME

NMS::Rancid::Node - Perl extension for Rancid

=head1 SYNOPSIS

  use NMS::Rancid;
  use NMS::Rancid::Node;
  my $rancid = new NMS::Rancid();
  my $node = $rancid->getNode($node_name);

  my $name = $node->name();
  my $vendor = $node->vendor();
  my $config_path = $node->configPath();
  $node->addConfigText($text);
  my $group = $node->group();
  my $rancid = $node->rancid();


=head1 DESCRIPTION

This Perl module reads and writes configration for Rancid nodes (devices).

=head2 Methods

=over 4

=item * $n->name();

Returns the name of the Node object.

=item * $n->vendor();

Returns the device type as defined in Rancid. A list of possible values can
be retrieved from ${$rancid->getVendors()}.

=item * $n->status();

Returns the device status as defined in Rancid's router.db.

=item * $result = $n->modify({status => 'up', vendor => 'cisco', model => 'C2960'});

Changes vendor and status attributes in rotuer.db. Argument is a hashref,
possible keys are: status, vendor, model. See setVendor and setStatus
methods for detailed usage.
Returns hashref with newly set values for status and vendor.

=item * $new_vendor = $n->setVendor({vendor => 'cisco', model => 'C2960'});

Changes vendor in rancid router.db file. This selects rancid script that
retrieves and parses device configuration. Two named arguments are accepted:
vendor - sets vendor directly,
model - sets vendor by looking up vendor for given model via equipment.conf

If both are passed, vendor argument will be used.
Returns vendor string on success and undef on errors.

=item * $new_status = $n->setStatus('up');

Changes status in rancid router.db file. Value up tells rancid to save
configuration for this device. Any other value disables saving configuration.
Returns new status string on success or undef on errors.

=item * $n->configPath();

Returns the path to the device configuration in CVS. CVS repo is selected by
storage_path Rancid constructor parameter.

=item * $n->getConfigText();

Returns configuration for device as is currnetly stored in rancid.

=item * $n->addConfigText($text);

Creates a new revision of device configuration as if rancid itself was run on
device. $text is piped through appropriate rancid script. Returns diff string
on success and undef on errors.

=item * $n->saveConfigText();

Calls appropriate *rancid scripts to save current configuration from device.
Return values: diff string on success and changes made, 1 on success and no
changes and undef on errors.

=item * $g->group();

Returns a NMS::Rancid::Group object that is parent of selected node. This is
a shorthand for ${$n->{group}}.

=item * $g->rancid();

Returns a NMS::Rancid object that is base of selected node. This is a
shorthand for ${${$self->{group}}->{rancid}}.

=back


=head1 SEE ALSO

perl(1)

=head1 AUTHOR

Matej Vadnjal, E<lt>matej.vadnjal@arnes.siE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2009 by Matej Vadnjal

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.0 or,
at your option, any later version of Perl 5 you may have available.


=cut


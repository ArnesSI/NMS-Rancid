# Perl module for Rancid (http://www.shrubbery.net/rancid/)
# Reads and writes Rancid configuration and provides lists of device
# configuration files.

package NMS::Rancid;

use strict;
use warnings;

our $VERSION = '0.10';

use Carp;
use File::Copy;

use NMS::Rancid::Group;
use NMS::Rancid::Node;
use NMS::Rancid::Cvs;

my @errors;

sub new {
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my %args = @_;
    my $self = {};
    $self->{base_path}    = $args{base_path}    || '/opt/rancid';
    $self->{config_path}  = $args{config_path}  || $self->{base_path}.'/etc';
    $self->{bin_path}     = $args{bin_path}     || $self->{base_path}.'/bin';
    $self->{dead_groups}  = $args{dead_groups}  || 'UKINJENO';
    $self->{cloginrc}     = $args{cloginrc}     || $ENV{HOME}.'/.cloginrc';
    $self->{encrypt_key_name}   = $args{encrypt_key_name} || undef;
    $self->{debug}        = $args{debug}        || 0;

    bless $self, $class;
    return $self->_init();
}

sub _init {
    my $self = shift;
    my $cvs;

    # remove trailing slashes
    $self->{base_path}    =~ s/\/*$//;
    $self->{config_path}  =~ s/\/*$//;
    $self->{bin_path}     =~ s/\/*$//;

    $self->_parseConfig();
    $self->_readSupportedVendors();
    $self->_readSupportedModels();
    $self->_prepareEnvironment();

    $self->{storage_path} = $self->{conf}->{BASEDIR};
    $self->{storage_path} =~ s/\/*$//;

    $self->{encrypt_cmd_template} = "/usr/bin/gpg -q --batch -r <recipient> -e --output <file>";

    $cvs= NMS::Rancid::Cvs->new(
        path => $self->{storage_path},
        cvsroot => $self->{conf}->{CVSROOT},
        debug => $self->{debug},
        rancid => \$self );
    $self->{cvs} = \$cvs;

    return $self;
}

sub addGroup {
    my $self = shift;
    my $group_name = shift;
    my @groups = $self->_getGroupList;
    my $cur_group;
    my $group;
    my $debug = $self->{debug};
    my ($group_dir,$configs_dir);
    my @routers;
    my $router_db;
    my $cvs;
    my $old_umask = umask 0007;

    # input validation
    if ($group_name !~ /^[a-zA-Z0-9\-_]+$/) {
        $self->_pushError("Invalid group name ($group_name)");
        return undef;
    }

    foreach $cur_group (@groups) {
        if ($group_name eq $cur_group) {
            $self->_pushError("Group $group_name already exists");
            return $self->getGroup($group_name);
        }
    }

    $cvs = $self->{cvs};

    # create group dir
    $group_dir = ${$cvs}->path().'/'.$group_name;
    if (! -d $group_dir) {
        mkdir($group_dir) || croak("Could not mkdir $group_dir");
    }
    ${$cvs}->cvsImport($group_dir, $group_name);
    ${$cvs}->co($group_dir);

    # create configs dir
    $configs_dir = $group_dir.'/configs';
    if (! -d $configs_dir) {
        mkdir($configs_dir) || croak("Could not mkdir $configs_dir");
    }
    ${$cvs}->add($configs_dir, 'new');
    ${$cvs}->commit($configs_dir);

    # routers.* files must be created only in BASEDIR and do not go in CVS
    @routers = qw(routers.all routers.down routers.up);
    foreach (@routers) {
        $_ = $group_dir.'/'.$_;
        open FH, ">", $_ or
            $self->_pushError("Could not touch $_. Do it manualy!");
        close FH;
    }

    # create router.db and add it to cvs
    $router_db = $group_dir.'/router.db';
    open FH, ">", $router_db or
        $self->_pushError("Could not touch $router_db. Do it manualy!");
    close FH;
    ${$cvs}->add($router_db, "new");
    ${$cvs}->commit($router_db);

    # write group name to rancid config file
    open LG, ">>", $self->{group_path} or
        croak("Could not open file with groups (",$self->{group_path},")");
    print LG "LIST_OF_GROUPS=\"\$LIST_OF_GROUPS $group_name\"\n";
    close LG;

    # update config variables
    $self->_parseConfig();

    # create object to return
    $group = NMS::Rancid::Group->new(
        name => $group_name,
        rancid => \$self);

    umask $old_umask;
    return $group;
}

sub delGroup {
    my $self = shift;
    my $group = shift;
    my @groups = $self->_getGroupList();
    my $group_name;
    my $cur_group;
    my $found = 0;
    my @lg_cont;
    my $debug = $self->{debug};
    my $cvs_cmd;
    my $ret;

    # were we passed group by name or by reference to a group object?
    $group_name = $group;
    $group_name = $group->name() if (ref($group));

    if (!defined $group_name || $group_name !~ /^[a-zA-Z0-9\-_]+$/) {
        $self->_pushError("Invalid group name $group_name");
        return undef;
    }

    foreach $cur_group (@groups) {
        if ($group_name eq $cur_group) {
            $found = 1;
            last;
        }
    }
    if (!$found) {
        $self->_pushError("Group $group_name does not exist");
        return undef;
    }

    $group = $self->getGroup($group_name) unless ref($group);

    # delete group folder in local cvs repos
    $cvs_cmd = "rm -rf ".$group->storagePath();
    $cvs_cmd.= " >/dev/null" if (!$debug);
    carp("'$cvs_cmd'") if ($debug);
    system($cvs_cmd) == 0 ||
        $self->_pushError("Error running '$cvs_cmd': $?");

    # we could be working in a different copy of cvs than $BASEDIR
    # remove group folder in $BASEDIR too
    if ($self->{conf}->{BASEDIR} ne $self->{storage_path}) {
        my $sys_group_path = $self->{conf}->{BASEDIR}.'/'.$group_name;
        $cvs_cmd = "rm -rf ".$sys_group_path;
        $cvs_cmd.= " >/dev/null" if (!$debug);
        carp("'$cvs_cmd'") if ($debug);
        system($cvs_cmd) == 0 ||
            $self->_pushError("Error running '$cvs_cmd': $?");
    }

    # do some cvs magic to "move" a group folder to archive
    $self->_cvsDelGroup($group);

    # remove group name form rancid config
    open LG, "<", $self->{group_path} or
        croak("Could not open file with groups (",$self->{group_path},")");
    @lg_cont = <LG>;
    close LG;
    @lg_cont = grep(!/ $group_name"/, @lg_cont);
    open LG, ">", $self->{group_path} or
        croak("Could not write to file with groups (",$self->{group_path},")");
    print LG @lg_cont;
    close LG;

    # update config variables
    $self->_parseConfig();

    return 1;
}

sub getGroup {
    my $self = shift;
    my $group_name = shift || undef;
    my @groups;
    my $group;

    if (!defined $group_name || $group_name !~ /^[a-zA-Z0-9\-_]+$/) {
        $self->_pushError("Invalid group name $group_name");
        return undef;
    }

    @groups = $self->_getGroupList();
    foreach (@groups) {
        if ($group_name eq $_) {
            $group = NMS::Rancid::Group->new(
                name => $group_name,
                rancid => \$self);
            return $group;
        }
    }
    $self->_pushError("Group $group_name does not exist");
    return undef;
}

sub getAllGroups {
    my $self = shift;
    my @group_list = $self->_getGroupList();
    my @groups;
    my $tmp_group;

    foreach (@group_list) {
        $tmp_group = NMS::Rancid::Group->new(
            name => $_,
            rancid => \$self);
        push @groups, $tmp_group;
    }
    return \@groups;
}

sub getNode {
    my $self = shift;
    my $node_name = shift || undef;
    my $nodes;
    my $node;

    if (!defined $node_name || $node_name !~ /^[a-zA-Z0-9\-]+$/) {
        $self->_pushError("Invalid node name $node_name");
        return undef;
    }

    $nodes = $self->getAllNodes();
    foreach $node (@{$nodes}) {
        return $node if ($node->name() eq $node_name);
    }
    $self->_pushError("Node $node_name not found");
    return undef;
}

sub getAllNodes {
    my $self = shift;
    my $groups;
    my @all_nodes;
    my ($group, $group_nodes);

    $groups = $self->getAllGroups();
    foreach $group (@$groups) {
        $group_nodes = $group->getAllNodes();
        push @all_nodes, @$group_nodes;
    }
    return \@all_nodes;
}

sub getAllNodesHash {
    my $self = shift;
    my $groups = $self->getAllGroups();
    my %all_nodes;
    my ($group, $group_nodes, $node);

    foreach $group (@$groups) {
        $group_nodes = $group->getAllNodes();
        foreach $node (@$group_nodes) {
            $all_nodes{$node->name()} = $node;
        }
    }
    return \%all_nodes;
}

sub getVendorFromModel {
    my $self = shift;
    my $model = shift;
    my $vendor = undef;

    foreach (@{ $self->{supported_models_arr} }) {
        if ($model =~ /$_/) {
            return $self->{supported_models}->{$_}[0];
        }
    }

    carp("Model $model not found. Using vendor cisco!");
    return 'cisco';
}

sub getMethodFromModel {
    my $self = shift;
    my $model = shift;
    my $method = undef;

    foreach (@{ $self->{supported_models_arr} }) {
        if ($model =~ /$_/) {
            return $self->{supported_models}->{$_}[1];
        }
    }

    carp("Model $model not found. Using access method telnet!");
    return 'telnet';
}

sub getVendors {
    my $self = shift;
    return sort keys(%{$self->{supported_vendors}});
}

sub getVendorScriptPath {
    my $self = shift;
    my $vendor = shift || '';

    if ($self->{supported_vendors}->{$vendor}) {
        return $self->{bin_path}.$self->{supported_vendors}->{$vendor};
    } else {
        $self->_pushError("Vendor $vendor not supported");
        return undef;
    }
}

# export cloginrc file
# input data is hashref with the following structure:
#  dev_name => {
#       username => 
#       password => 
#       epassword =>
#       [model|vendor] => vendor or model must be given
#       method => optional, can be determined if model is given
#       timeout => optional
#  }
#  dev_name_2 => { ...
#
# cloginrc file is overwritten
# cloginrc can be encrypted if $self->{encrypt_key_name} is defined
# and set to gpg key recipient in gpg keychain for current user
sub exportCloginrc {
    my $self = shift;
    my $device_data = shift;
    my $cloginrc_str = "";
    my $cloginrc_tmp = $self->{cloginrc}.".tmp";

    foreach my $dev_name (keys %{$device_data}) {
        my $dev = $device_data->{$dev_name};
        if (defined $dev->{model} && ! defined $dev->{vendor}) {
            $dev->{vendor} = $self->getVendorFromModel($dev->{model});
        }
        if (! defined $dev->{method}) {
            if (defined $dev->{model}) {
                $dev->{method} = $self->getMethodFromModel($dev->{model});
            }
            else {
                $dev->{method} = 'telnet';
            }
        }
        if (!defined $dev->{password}) {
            $dev->{password} = "";
        }
        if (!defined $dev->{epassword}) {
            $dev->{epassword} = "";
        }
        $cloginrc_str .= "add user $dev_name ".$dev->{username}."\n"
            if (defined $dev->{username});
        $cloginrc_str .= "add password $dev_name ".$dev->{password}." ".$dev->{epassword}."\n";
        $cloginrc_str .= "add method $dev_name ".$dev->{method}."\n";
        $cloginrc_str .= "add timeout $dev_name ".$dev->{timeout}."\n"
            if (defined $dev->{timeout});
        $cloginrc_str .= "\n";
    }

    if (-f $cloginrc_tmp && ! unlink $cloginrc_tmp) {
        croak("Could not remove $cloginrc_tmp");
    }
    if (defined $self->{encrypt_key_name}) {
        my $encrypt_cmd = $self->{encrypt_cmd_template};
        $encrypt_cmd =~ s/<recipient>/$self->{encrypt_key_name}/;
        $encrypt_cmd =~ s/<file>/$cloginrc_tmp/;
        print STDERR "$encrypt_cmd\n" if $self->{debug};
        unless (open(WRITE, "|$encrypt_cmd")) {
            croak("ERROR: Cannot write to gpg pipe ($!)");
        }
    }
    else {
        unless (open(WRITE, ">$cloginrc_tmp")) {
            croak("ERROR: Cannot write to tmp cloginrc [$cloginrc_tmp] ($!)");
        }
    }
    print WRITE $cloginrc_str;
    close WRITE;
    unless (chmod(0600, $cloginrc_tmp)) {
        croak("Cannot chmod $cloginrc_tmp");
    }
    unless (move($cloginrc_tmp, $self->{cloginrc})){
        croak("ERROR Cannot move $cloginrc_tmp to ".$self->{cloginrc}." ($!)");
    }
}

sub isError {
    my $self = shift;
    if (scalar @NMS::Rancid::errors>0) {
        return 1;
    }
    return 0;
}

sub getErrorString {
    my $self = shift;
    return join("\n", @{ $self->getErrors() });
}

sub getErrors {
    my $self = shift;
    my @errors_r;

    if (scalar @NMS::Rancid::errors>0) {
        push @errors_r, @NMS::Rancid::errors;
    }

    # clear errors
    $self->_clearErrors();

    return \@errors_r;
}


sub _readSupportedModels {
    my $self = shift;
    # order of lines in file is important so we use an array
    # to preserve order
    my (%models, @models_arr);
    my $model_conf;

    $model_conf = $self->{config_path}.'/equipment.conf';
    open M, $model_conf or croak("Could not open $model_conf");
    while (<M>) {
        chomp;
        next if /^\s*[#;]/; # skip comments
        next if (/^\s*$/);
        if (/^\s*(\S+?)\s+(\S+?)\s+(.+)$/) {
            $models{$1} = [ $2, $3 ];
            push @models_arr, $1;
        }
    }
    close M;

    if (scalar @models_arr < 1) {
        carp("No model definitions found in $model_conf");
    }

    $self->{supported_models} = \%models;
    $self->{supported_models_arr} = \@models_arr;
}

sub _readSupportedVendors {
    my $self = shift;
    my %vendors;
    my $rancid_fe;

    $rancid_fe = $self->{bin_path}.'/rancid-fe';
    open FE, $rancid_fe or croak("Could not open $rancid_fe");
    while (<FE>) {
        if (/^\s+'(\w+)'\s+=>\s+'(\w+)',\s*$/) {
            $vendors{$1} = $2;
        }
    }
    close FE;
    $self->{supported_vendors} = \%vendors;
}

sub _getGroupList {
    my $self = shift;
    my @groups;
    @groups = split(/ /, $self->{conf}->{LIST_OF_GROUPS});
    return @groups;
}

# take conf variables and put them in shells environment
# some commands run by this module need them
sub _prepareEnvironment {
    my $self = shift;
    foreach (keys %{ $self->{conf} }) {
        $ENV{$_} = $self->{conf}->{$_};
    }
}

sub _parseConfig {
    my $self = shift;
    my $cnf;
    my $rancid_conf = $self->{config_path}.'/rancid.conf';

    $self->_parseConfigFile($rancid_conf);
    return $self;
}

sub _parseConfigFile {
    my $self = shift;
    my $conf = shift;
    my $var_name;
    my $var_value;
    my $cnf;
    my $fh;

    open ($cnf, $conf) or
        croak("Coud not open rancid config $conf");

    while (<$cnf>) {
        next if (/^\s*#/);
        next if (/^\s*$/);
        if (/(\w+)=([^;]+)/) {
            $var_name = $1;
            $var_value = $2;
            chomp $var_value;
            $var_value =~ s/\$(\w+)/$self->{conf}->{$1}/;
            $var_value =~ s/"//g;
            $var_value =~ s/^\s+//;
            $self->{conf}->{$var_name} = $var_value;

            # remember which file containg LIST_OF_GROUPS (for addGroup) method
            $self->{group_path} = $conf if ($var_name eq 'LIST_OF_GROUPS');
            next;
        }
        if (/\.\s+([\w\/\.]+)/) {
            $self->_parseConfigFile($1);
        }
    }
    close $cnf;
}


# move folder in cvs to subdir and co in local repos
sub _cvsDelGroup {
    my $self = shift;
    my $group = shift;
    my $debug = $self->{debug};
    my $cvs_cmd;
    my $cvsroot = $self->{conf}->{CVSROOT};
    my $suffix = time();
    my $cvs_path;
    my $cvs_dead_path;
    my $old_umask = umask 0007;

    # check if $cvsroot/{dead_groups} exists and create if neccessary
    if (! -d $cvsroot.'/'.$self->{dead_groups}) {
        if (!mkdir($cvsroot.'/'.$self->{dead_groups})) {
            croak("Could not create ".$cvsroot.'/'.$self->{dead_groups}.": $!");
        }
    }

    $cvs_path = $cvsroot.'/'.$group->name();
    $cvs_dead_path = $cvsroot.'/'.$self->{dead_groups}.'/'.$group->name();
    # check if $cvs_path exists and add suffix
    $cvs_dead_path.= '.'.$suffix if (-d $cvs_dead_path);
    if (-d $cvs_path) {
        move($cvs_path, $cvs_dead_path) ||
            croak("Could not move $cvs_path to $cvs_dead_path: $!");
    } else {
        carp("Path $cvs_path is not a folder. Not moving it.");
    }

    # run cvs co in local repos
    $self->_cvsCheckout($self->{storage_path}.'/'.$self->{dead_groups});

    umask $old_umask;
    return 1;
}

# updates cvs
sub _cvsUpdate {
    my $self = shift;
    my $path = shift;
    my $rel_path;
    my $cvs_path = ${$self->{cvs}}->path();
    my $base_path;

    if ($path =~ /^$cvs_path\/(.+)/) {
        $rel_path = $1;
    } else {
        croak("Path $path not in cvs ($cvs_path)");
    }
    return undef unless ${$self->{cvs}}->update($path);
    return 1;
}

# checkout cvs
sub _cvsCheckout {
    my $self = shift;
    my $path = shift;
    my $rel_path;
    my $cvs_path = ${$self->{cvs}}->path();
    my $base_path;

    if ($path =~ /^$cvs_path\/(.+)/) {
        $rel_path = $1;
    } else {
        croak("Path $path not in cvs ($cvs_path)");
    }
    return undef unless ${$self->{cvs}}->co($path);
    return 1;
}

sub _cvsDiff {
    my $self = shift;
    my $path = shift;
    my $mail_rcpt = shift || undef;
    my $cvs_path = ${$self->{cvs}}->path();
    my $diff;
    my $rel_path;
    my $mail;

    if ($path =~ /^$cvs_path\/(.+)/) {
        $rel_path = $1;
        $rel_path =~ s/configs\///;
    } else {
        croak("Path $path not in cvs ($cvs_path)");
    }

    $diff = ${$self->{cvs}}->diff($path);
    return undef unless defined $diff;
    return 1 if ($diff eq ''); # no changes, but that's ok too

    $diff =~ s/Index: (.+)\/configs/Index: $1/g;

    # mail diff
    if (defined $mail_rcpt) {
        $mail = "To: ".$mail_rcpt."\n";
        $mail.= "Subject: ".$rel_path." router config diffs\n";
        $mail.= "Precedence: bulk\n";
        $mail.= "\n";
        $mail.= $diff."\n.\n";

        if (system("/bin/echo '$mail' | /usr/sbin/sendmail -t") != 0) {
            $self->_pushError("Could not send diff mail: $?");
            return undef;
        }
    }

    return $diff;
}


sub _pushError {
    my $self = shift;
    my $errstr = shift;
    if ($self->{debug}) {
        my ($package,$filename,$line,$sub) = caller(1);
        $errstr = sprintf('%s (in %s at %s line %s, sub %s)', $errstr,$package,$filename,$line,$sub);
    }
    push (@NMS::Rancid::errors, $errstr);
}

sub _clearErrors {
    my $self = shift;

    undef @NMS::Rancid::errors;
}


1;
__END__

=head1 NAME

NMS::Rancid - Perl extension for Rancid

=head1 SYNOPSIS

  use NMS::Rancid;
  my $rancid = new NMS::Rancid(
        rancid_path  => '/opt/rancid'
        );
  my $group = $rancid->getGroup('myGroup');
  my $group = $rancid->addGroup('otherGroup');
  my $true = $rancid->delGroup('otherGroup');
  my $groups_ref = $rancid->getAllGroups();
  my $node = $rancid->getNode('myNode');
  my $nodes_ref = $rancid->getAllNodes();
  my @vendor_list = $rancid->getVendors();
  my $script_path = $rancid->getVendorScriptPath($vendor);
  $rancid->exportCloginrc({
        host1 => {
              username => 'root',
              password => 'secret',
              epassword => 'supersecret',
              vendor => 'juniper',
              method => '{ssh} {telnet}',
              timeout => 10
        },
        host2 => {
        ...
  });

=head1 DESCRIPTION

This Perl modules reads and writes configration for Rancid (Really
Awesome New Cisco confIg Differ, http://www.shrubbery.net/rancid/).

=head2 Methods

=over 4

=item * $r = new NMS::Rancid([%options]);

Create a new NMS::Rancid object. Options hash can contain the following keys:

=over 4

=item * base_path - Path to the base of rancid installation.

Default: /opt/rancid

=item * config_path - Path to rancid configuration files.

Default: $base_path/etc

=item * storage_path - Path to the root of rancid CVS. If you keep
a seperate copy of CVS repo in another folder you can set it here.
All CVS operations will be done in this repo and Rancid's base repo.

Default: $base_path/var

=item * bin_path - Path to rancid executable scripts.

Default: $base_path/bin

=item * dead_groups - The name of group to move groups when deleting them. All group and
nodes in this group are "invisible" to Rancid and this module. They
are stored here for archival purposes.

Default: 'UKINJENO'

=item * cloginrc - Path to cloginrc file. You may export device passwords to
this file via exportCloginrc() method.

Default: $ENV{HOME}/.cloginrc

=item * encrypt_key_name - Name of GPG key (recipient) to encrypt exported 
cloginrc file with. If not defined the file is exported in clear text. The
key must be known to GPG keychain for user running this library before 
exporting.

Note: for this to be usefull, your Rancid *login scripts must be able to
decrypt the cloginrc file.

Default: undef

=item * debug - 1: enable debugging (prints messages to STDOUT), 0: disable debugging.

Default: 0

=back

=item * $r->getGroup($name);

Returns an instance of NMS::Rancid::Group object matching $name.
If group $name does not exist in configuration it returns undef.

=item * $r->addGroup($name);

Adds a group with name $name to Rancid. Writes configuration files
and creates appropriate CVS folders.
Returns an instance of NMS::Rancid::Group object representing the
new group. If a group with the same name allready exists, it will
return a NMS::Rancid::Group object representing thet group. On
errors returns undef.

=item * $r->delGroup($name);

Moves a group $name as a sub-group to $dead_groups. Automatically
takes care of configuration files and CVS repositories.
Returns 1 on success and undef on error.

=item * $r->getAllGroups();

Return all groups in Rancid. Return value is a reference to a list
of NMS::Rancid::Group objects representing Rancid groups.

=item * $r->getNode($name);

Returns a NMS::Rancid::Node object representing a node $name. The
node is searched for in all Rancid groups.
On errors returns undef.

=item * $r->getAllNodes();

Returns a reference to a list of NMS::Rancid::Node objects. Each
object represents a node in Rancid. All nodes are returned, regardles
of the group they are in with the exception of $dead_groups.
On errors return undef.

=item * $r->getVendorFromModel($model);

Returns rancid vendor name for given model string. This determines
which script is used to read configurations for this model of device.
A list of regular expressions that a model must match is read from
{config_path}/equipment.conf
If no regex matches model default vendor 'cisco' is used.

=item * $r->getMethodFromModel($model);

Returns rancid access method for given model string. This determines
how to connect to device of this model to read configurations.
A list of regular expressions that a model must match is read from
{config_path}/equipment.conf
If no regex matches model default method 'telnet' is used.

=item * $r->getVendors();

Returns a list of all device types that are supported in this Rancid
instalation. A list of vendors is read from {bin_path}/rancid-fe

=item * $r->getVendorScriptPath($vendor);

Returns a path to a rancid script responsible for parsing configurations
of devices of given vendor.
Returns unfed on errors.

=item * $r->exportCloginrc($device_data);

Writes cloginrc file based on data in hashref $device_data.
Cloginrc path can be specified at object initialization via cloginrc
argument.
Expected $device_data structure is:
   dev_name => {
        username => 
        password => 
        epassword =>
        [model|vendor] => vendor or model must be given
        method => optional, can be determined if model is given
        timeout => optional
   }
   dev_name_2 => { ...
 
Any existing cloginrc file will be overwritten.
If encrypt_key_name argument is defined at object initialization, the exported
file will be encrypted with GPG key of recipient in encrypt_key_name. The
recipient must be known in GPG keychain before exporting.

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

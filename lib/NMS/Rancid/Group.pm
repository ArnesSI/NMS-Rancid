# Perl module for Rancid (http://www.shrubbery.net/rancid/)
# Reads and writes Rancid configuration and provides lists of device
# configuration files.

package NMS::Rancid::Group;

use strict;
use warnings;

use base qw( NMS::Rancid );

use Carp;
use NMS::Rancid::Node;
use NMS::Rancid::Cvs;

sub new {
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my %args = @_;
    my $self = {};
    $self->{name} = $args{name} || croak("Group name not defined");
    $self->{rancid} = $args{rancid} || croak("No reference to rancid object");
    bless $self, $class;
    return $self->_init();
}

sub _init {
    my $self = shift;

    $self->{storage_path} = $self->rancid()->{storage_path}.'/'.$self->{name};

    # set mail addresses for diffs
    $self->{mailrcpt} = "rancid-".$self->name();
    $self->{mailrcpt} .= $self->rancid()->{conf}->{MAILDOMAIN}
        if ($self->rancid()->{conf}->{MAILDOMAIN});

    $self->{adminmailrcpt} = "rancid-admin-".$self->name();
    $self->{adminmailrcpt} .= $self->rancid()->{conf}->{MAILDOMAIN}
        if ($self->rancid()->{conf}->{MAILDOMAIN});

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

sub storagePath {
    my $self = shift;
    return $self->{storage_path};
}

sub addNode {
    my $self = shift;
    my ($args) = @_;
    my $node_name = $args->{name} || undef;
    my $vendor;
    my $nodes;
    my $node;
    my $cur_node;
    my $router_db = 'router.db'; # TODO make global
    my $router_path;
    my $node_config;
    my $old_umask = umask 0007;

    # validate name
    if ($node_name !~ /^[a-zA-Z0-9\-]+$/) {
        $self->rancid()->_pushError("Invalid node name ($node_name)");
        return undef;
    }

    # determine and validate vendor, possibly from model
    if (!defined $args->{vendor} && !defined $args->{model}) {
        $self->rancid()->_pushError("Error adding node $node_name. Missing model or vendor argument.");
        return undef;
    }
    elsif (defined $args->{vendor}) {
        $vendor = $args->{vendor};
    }
    elsif (defined $args->{model}) {
        $vendor = $self->rancid()->getVendorFromModel($args->{model});
    }
    else {
        $self->rancid()->_pushError("Unknown error while determining node vendor.");
        return undef;
    }

    unless ($self->rancid()->{supported_vendors}->{$vendor}) {
        $self->rancid()->_pushError("Error adding node $node_name. Vendor $vendor not supported.");
        return undef;
    }

    # validate status
    my $status = $args->{status} || 'up';
    if ($status !~ /^[a-zA-Z]+$/) {
        $self->rancid()->_pushError("Error adding node $node_name. Bad status given [$status].");
        return undef;
    }

    $nodes = $self->rancid()->getAllNodes();
    foreach $cur_node (@$nodes) {
        if ($node_name eq $cur_node->name()) {
            $self->rancid()->_pushError("Node $node_name already exists");
            return undef;
        }
    }

    # write appropriate router DB
    $router_path = $self->storagePath.'/'.$router_db;
    open DB, ">>", $router_path or
        croak("Could not open router.db for group (",$self->name(),")");
    print DB "$node_name:$vendor:$status\n";
    close DB;

    # create node object
    $node = NMS::Rancid::Node->new(
        name => $node_name,
        group => \$self);

    # create empty node config file
    $node_config = $node->configPath();
    if (! -e $node_config) {
        open CF, ">", $node_config or
            croak("Could not create node config file (",$node_config,")");
        close CF;
    }

    umask $old_umask;

    # commit changes (router.db, node config) to cvs and update
    return undef unless ${$self->rancid()->{cvs}}->add($node->configPath());
    return undef unless ${$self->rancid()->{cvs}}->commit($self->storagePath(), "new router");
    return undef unless $self->rancid()->_cvsUpdate($self->storagePath());
    return $node;
}

sub delNode {
    my $self = shift;
    my $node_name = shift;
    my $node;
    my $router_db = 'router.db';
    my $router_path;
    my @db_lines;

    if (!defined $node_name || $node_name !~ /^[a-zA-Z0-9\-]+$/) {
        $self->rancid()->_pushError("Invalid node name $node_name");
        return undef;
    }

    $node = $self->getNode($node_name);
    # input validation
    return undef if (!defined($node));

    # delete node config file
    unlink($node->configPath()) ||
        croak("Could not delete ",$node->configPath());

    # remove from router.db
    $router_path = $self->storagePath.'/'.$router_db;
    open DB, "<", $router_path or
        croak("Could not open router.db for reading ($router_path)");
    @db_lines = <DB>;
    close DB;
    @db_lines = grep(!/^\s*$node_name:/, @db_lines);
    open DB, ">", $router_path or
        croak("Could not open router.db for writing ($router_path)");
    print DB @db_lines;
    close DB;

    # cvs delete, commit and upadte
    return undef unless ${$self->rancid()->{cvs}}->delete($node->configPath());
    return undef unless ${$self->rancid()->{cvs}}->commit($self->storagePath(), "deleted router");
    return undef unless $self->rancid()->_cvsUpdate($self->storagePath());

    return 1;
}

sub getNode {
    my $self = shift;
    my $node_name = shift || undef;
    my @nodes;
    my $node;

    if (!defined $node_name || $node_name !~ /^[a-zA-Z0-9\-]+$/) {
        $self->rancid()->_pushError("Invalid node name $node_name");
        return undef;
    }

    @nodes = $self->_getNodeList();
    foreach (@nodes) {
        if ($node_name eq $_) {
            $node = NMS::Rancid::Node->new(
                name => $node_name,
                group => \$self);
            return $node;
        }
    }
    $self->rancid()->_pushError("Node $node_name not found");
    return undef;
}

sub getAllNodes {
    my $self = shift;
    my @node_list;
    my $tmp_node;
    my @nodes;

    @node_list = $self->_getNodeList;
    foreach (@node_list) {
        $tmp_node = NMS::Rancid::Node->new(
            name => $_,
            group => \$self);
        push @nodes, $tmp_node;
    }

    return \@nodes;
}

sub rancid {
    my $self = shift;
    return ${$self->{rancid}};
}

sub _getNodeList {
    my $self = shift;
    my $router_db = 'router.db';
    my $router_path = $self->storagePath.'/'.$router_db;
    my @node_list = $self->_nodesFromRouterDB($router_path);

    return @node_list;
}

sub _nodesFromRouterDB {
    my $self = shift;
    my $db = shift;
    my @nodes;
    open(DB, $db) or croak("Could not open router.db: $db");

    while (<DB>) {
        chomp;
        next if /^\s*[#;]/;
        next if /^\s*$/;
        if (/^(.+?):.*/) {
            push @nodes, $1; }
    }
    close DB;
    return @nodes;
}


1;
__END__


=head1 NAME

NMS::Rancid::Group - Perl extension for Rancid

=head1 SYNOPSIS

  use NMS::Rancid;
  use NMS::Rancid::Group;
  my $rancid = new NMS::Rancid();
  my $group = $rancid->getGroup('myGroup');

  my $name = $group->name();
  my $storage_path = $group->storagePath();
  my $node = $group->addNode($node_name, $node_model, $node_status);
  $group->delNode($node_name);
  my $node = $group->getNode($node_name);
  my $nodes_ref = $group->getAllNodes();
  my $rancid = $group->rancid();


=head1 DESCRIPTION

This Perl modules reads and writes configration for Rancid groups.

=head2 Methods

=over 4

=item * $g->name();

Returns the name of the Group object.

=item * $g->storagePath();

Returns the path to the CVS direcory containing configuration files.
CVS repo is selected by storage_path Rancid constructor parameter.

=item * $g->addNode($node_config);

Adds a node to Rancid group. This writes appropriate Rancid
configuration files. Returns an instance of NMS::Rancid::Node.
Argument is a hashref with keys:

name - The name of device

vendor - The vendor of device. Possible values are defined in
         [bin_path]/rancid-fe

model - Model of device. Appropriate vendor is looked up via equipment.conf

status - Is device reachable. If device is marked as down,
         rancid will not attempt to backup its configuration.
         Possible values: up, down.

=item * $g->delNode($node_name);

Removes node from Rancid configuration files and marks devices
configuration files as dead in CVS. Returns 1 on successfull deletion or
undef on errors.

=item * $g->getNode($node_name);

Returns a NMS::Rancid::Node object representing a node $node_name. The
node is searched for only in selected Rancid group.
On errors returns undef.

=item * $g->getAllNodes();

Returns a reference to a list of NMS::Rancid::Node objects. Each
object represents a node in selected Rancid group.
On errors return undef.

=item * $g->rancid();

Returns a NMS::Rancid object that is parent of selected group. This is a
shorthand for ${$g->{rancid}}.

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


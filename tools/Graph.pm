package Graph;

use utf8;
use namespace::autoclean;

use Carp;
use Moose;
use MooseX::SemiAffordanceAccessor; # attribute x is written using set_x($value) and read using x()
use List::MoreUtils qw(any);
use Node;



has 'comments' => (is => 'ro', isa => 'ArrayRef', default => sub {[]}, documentation => 'Sentence-level CoNLL-U comments.');
has 'nodes'    => (is => 'ro', isa => 'HashRef', default => sub {my $self = shift; {0 => new Node('id' => 0, 'graph' => $self)}});



#------------------------------------------------------------------------------
# Checks whether there is a node with the given id.
#------------------------------------------------------------------------------
sub has_node
{
    confess('Incorrect number of arguments') if(scalar(@_) != 2);
    my $self = shift;
    my $id = shift;
    confess('Undefined id') if(!defined($id));
    return exists($self->nodes()->{$id});
}



#------------------------------------------------------------------------------
# Returns node with the given id. If there is no such node, returns undef.
#------------------------------------------------------------------------------
sub get_node
{
    confess('Incorrect number of arguments') if(scalar(@_) != 2);
    my $self = shift;
    my $id = shift;
    confess('Undefined id') if(!defined($id));
    return $self->has_node($id) ? $self->nodes()->{$id} : undef;
}



#------------------------------------------------------------------------------
# Returns node with the given id. If there is no such node, returns undef.
# This method is just an alias for get_node().
#------------------------------------------------------------------------------
sub node
{
    my $self = shift;
    my $id = shift;
    return $self->get_node($id);
}



#------------------------------------------------------------------------------
# Returns the list of all nodes except the artificial root node with id 0. The
# list is ordered by node ids.
#------------------------------------------------------------------------------
sub get_nodes
{
    confess('Incorrect number of arguments') if(scalar(@_) != 1);
    my $self = shift;
    my @list = map {$self->get_node($_)} (sort
    {
        Node::cmpids($a, $b)
    }
    (grep {$_ ne '0'} (keys(%{$self->nodes()}))));
    return @list;
}



#------------------------------------------------------------------------------
# Adds a node to the graph. The node must have a non-empty id that has not been
# used by any other node previously added to the graph.
#------------------------------------------------------------------------------
sub add_node
{
    confess('Incorrect number of arguments') if(scalar(@_) != 2);
    my $self = shift;
    my $node = shift;
    my $id = $node->id();
    if(!defined($id))
    {
        confess('Cannot add node with undefined ID');
    }
    if($self->has_node($id))
    {
        confess("There is already a node with ID $id in the graph");
    }
    $self->nodes()->{$id} = $node;
    $node->set_graph($self);
}



__PACKAGE__->meta->make_immutable();

1;



=for Pod::Coverage BUILD

=encoding utf-8

=head1 NAME

Graph

=head1 DESCRIPTION

A C<Graph> holds a list of nodes and can return the C<Node> based on its
C<ID> (the first column in a CoNLL-U file, can be integer or a decimal number).
Edges are stored in nodes.

=head1 ATTRIBUTES

=over

=item parent

Refers to the parent C<Phrase>, if any.

=back

=head1 METHODS

=over

=item $phrase->set_parent ($nonterminal_phrase);

Sets a new parent for this phrase. The parent phrase must be a L<nonterminal|Treex::Core::Phrase::NTerm>.
This phrase will become its new I<non-head> child.
The new parent may also be undefined, which means that the current phrase will
be disconnected from the phrase structure (but it will keeep its own children,
if any).
The method returns the old parent.

=back

=head1 AUTHORS

Daniel Zeman <zeman@ufal.mff.cuni.cz>

=head1 COPYRIGHT AND LICENSE

Copyright © 2019 by Institute of Formal and Applied Linguistics, Charles University in Prague
This module is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

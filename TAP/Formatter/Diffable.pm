use strict;

package TAP::Formatter::Diffable;
use base 'TAP::Base', 'TAP::Formatter::File';
use accessors qw(sessions);

sub _initialize {
    my ($self, $hash) = @_;
    $self->sessions( [] );
    $self->$_( $hash->{$_} ) for keys %$hash;
    return $self;
}

sub _output {
    my $self = shift;
    print @_;
}

sub open_test {
    my ($self, $test, $parser) = @_;
    my $session = TAP::Formatter::Diffable::Session->new({
        test => $test,
        parser => $parser,
        formatter => $self,
    });
    push @{ $self->sessions }, $session;
    return $session;
}

sub summary {
    my $self = shift;

    my %sessions;
    $sessions{ $_->test } = $_ for @{ $self->sessions };

    # Sorting by test, that's what this module is all about.
    # Sorted output is diffable.
    for (sort keys %sessions) {
        $sessions{ $_ }->is_interesting or next;
        $self->_output( $sessions{ $_ }->as_report );
        $self->_output( "\n" );
    }

    # Elapsed time makes the output undiffable.
    local *TAP::Parser::Aggregator::timestr = sub { "" };

    $self->SUPER::summary(@_);
}


package TAP::Formatter::Diffable::Session;
use base 'TAP::Base';
use accessors qw( test formatter parser results );

sub _initialize {
    my ($self, $hash) = @_;
    $self->results( [] );
    $self->$_( $hash->{$_} ) for keys %$hash;
    return $self;
}

sub result {
    my ($self, $result) = @_;

    return unless $result->is_test;
    return if $result->is_actual_ok and not $result->has_todo;
    return if $result->has_todo and not $result->is_actual_ok;

    push @{ $self->results }, $result->as_string;
}

sub close_test {
}

sub is_interesting {
    my ($self) = @_;
    return !! @{ $self->results };
};

sub as_report {
    my ($self) = @_;
    return join "", map "$_\n", "[" . $self->test . "]", @{ $self->results };
}

1;

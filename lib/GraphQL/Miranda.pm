use v5.28.0;
use warnings;
package GraphQL::Miranda;

use Data::OptList;
use Safe::Isa;
use Scalar::Util qw(blessed);

package GraphQL::Miranda::Selection {
}

package GraphQL::Miranda::Field {
  our @ISA = qw(GraphQL::Miranda::Selection);

  sub new {
    my ($class, $name, $arg) = @_;
    $arg //= {};

    state %known = map {; $_ => 1 } qw( alias args select );

    my %guts = (
      name => $name,

      alias   => $arg->{alias},
      args    => ($arg->{args}
                ? GraphQL::Miranda::Args->_new($arg->{args})
                : undef),
      select  => ($arg->{select}
                ? GraphQL::Miranda->selection_set($arg->{select}->@*)
                : undef),
    );

    my @unknown = grep {; ! $known{$_} } keys %$arg;

    Carp::confess("unknown args when creating field selector: @unknown")
      if @unknown;

    bless \%guts, $class;
  }

  sub as_string {
    my ($self, $indent) = @_;
    $indent //= "";

    my $string  = defined $self->{alias}
                ? "$indent$self->{alias}: $self->{name}"
                : "$indent$self->{name}";

    if ($self->{args}) {
      $string .= "(\n"
              . $self->{args}->as_string("  $indent")
              . "$indent)";
    }

    if ($self->{select}) {
      $string .= " {\n"
              .  $self->{select}->as_string("  $indent")
              .  "\n$indent\}";
    }

    return $string;
  }
}

package GraphQL::Miranda::SelectionSet {
  sub _new {
    my ($class, $aref) = @_;
    bless { selections => $aref }, $class;
  }

  sub as_string {
    my ($self, $indent) = @_;
    $indent //= "";

    return join qq{\n},
      (map {; $_->as_string($indent) } $self->{selections}->@*),
  }
}

package GraphQL::Miranda::Args {
  use Cpanel::JSON::XS;
  my $JSON = Cpanel::JSON::XS->new->allow_nonref;

  use Params::Util qw(_HASH0 _ARRAY0);

  sub _new {
    my ($class, $href) = @_;
    bless { args => $href }, $class;
  }

  my sub _stringify_value {
    my ($value, $indent) = @_;
    if (_HASH0($value)) {
      my $substr = GraphQL::Miranda::Args->_new($value)->as_string("  $indent");
      return "{\n$substr$indent}";
    }

    if (_ARRAY0($value)) {
      return join qq{\n},
        "[",
        (map {; "  $indent" . __SUB__->($_, "  $indent") } @$value),
        "$indent]";
    }

    return $JSON->encode($value);
  }

  sub as_string {
    my ($self, $indent) = @_;
    $indent //= "";

    my $args = $self->{args};

    my $str = q{};
    for my $key (sort keys %$args) {
      $str .= "$indent$key: " . _stringify_value($args->{$key}, $indent) . "\n";
    }

    return $str;
  }
}

sub selection_set {
  my ($self, @rest) = @_;

  my @selections;

  IDX: for (my $i = 0; $i < @rest; $i++) {
    my $this = $rest[$i];

    if ($this->$_isa('GraphQL::Miranda::Selection')) {
      push @selections, $this;
      next IDX;
    }

    if (! ref $this) {
      my $arg = (ref $rest[$i+1] && ! blessed $rest[$i+1])
              ? $rest[++$i] # If the next item is {...} it's args here.
              : {};

      push @selections, GraphQL::Miranda::Field->new($this, $arg);
      next IDX;
    }

    Carp::confess("encountered weird thing in selection set: $this");
  }

  return GraphQL::Miranda::SelectionSet->_new(\@selections);
}

1;

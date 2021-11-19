use v5.34.0;
use warnings;

package Linear::TestClient;
use Moose;
extends 'Linear::Client';

use experimental 'signatures';

use Future::AsyncAwait;

sub _http {
  Carp::confess("Tried to access HTTP client on offline test client");
}

has authenticated_userId => (
  is    => 'ro',
  lazy  => 1,
  default => sub {
    Carp::confess("tried to read authenticated_userId but none set");
  },
);

async sub get_authenticated_userId ($self) {
  $self->authenticated_userId;
}

for my $attr (qw( label state user team )) {
  my $plural = "${attr}s";

  my $reader    = "_test_$plural";
  my $predicate = "_has_test_$plural";

  has $attr => (
    reader    => $reader,
    predicate => $predicate,
  );

  Sub::Install::install_sub({
    as    => $plural,
    code  => async sub ($self) {
      Carp::confess("Tried to call ->$plural but no test $plural set!")
        unless $self->$predicate;

      return $self->$reader;
    }
  });

  Sub::Install::install_sub({
    as    => "lookup_$attr",
    code  => async sub ($self, $key) {
      Carp::confess("Tried to call ->lookup_$attr but no test $plural set!")
        unless $self->$predicate;

      my $dict = await $self->$plural;
      return $dict->{ $key };
    }
  });
}

no Moose;
1;

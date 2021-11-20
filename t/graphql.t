use v5.28.0;
use warnings;

use Test::More;
use GraphQL::Miranda;

my $set = GraphQL::Miranda->selection_set(
  name  =>
  title => { alias => 'honorific' },
  age   =>
  birthday => { select => [ qw( year month day ) ] },

  photo => { alias => 'bigPhoto', args => { x => 1024, y => 768 } },
  photo => { alias => 'weePhoto' },

  contact => {
    select => [ 'email' ],
    args   => {
      filter => {
        id    => { eq => 'rjbs@gorp.int' },
        zones => [ 'EU', 'AF', { treatGeorgiaAs => 'Asia' } ],
      }
    },
  },
);

note $set->as_string;

pass("Look, this doesn't really test anything, it just emits.");
done_testing;

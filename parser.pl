use v5.30.0;
use warnings;

my $plusplus = qr{\+\+};
my $user_at_team = qr{(^\w+)(?:@(\w+))?};
my $at_team = qr{^@(?<team>\w+)};
my $angle = qr{>>};


my @strings = (
  #"++ eat pie",
  ">> rasha eat shawarma",
  #'>> rjbs@home eat pie',
  '>> @fastmail eat cake',
);

my $assignee;
my $team;
my $task;

for my $string (@strings) {
  if ($string =~ s/\A$plusplus\s+//) {
    say "PLUS!  ($string) remains";
    $task = $string;
  } elsif ($string =~ s/\A$angle\s+//) { # removes the >> from $string
    my $target;
    ($target, $string) = split /\s+/, $string, 2;

    my $username;
    my $teamname;

    if ($target =~ /\A([a-z]+)@([a-z]+)\z/) {
      $username = $1;
      $teamname = $2;
    }

    # Rik imagines something like:  $self->_resolve_user_and_team($lhs, $rhs)
    # where...
    #   if /@/: $lhs = $username, $rhs = $teamname
    #   else  : $lhs = $target
    # ...and it returns a Future whose eventual value will be a hashref like:
    #   { user_id => $guid, team_id => $guid }
    # ...where user_id can be undef, but team_id must not.
    # -- rjbs, 2021-12-06
  } else {
    # We need a better failure strategy than cussing. :)
    # Probably: return Future->fail(...)
    die "Shit.";
  }

  $string =~ s/\A\s+//;

  say "...now we have to parse ($string)";
}

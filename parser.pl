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
  if ($string =~ s/\A$plusplus//) {
    $string =~ s/\A\s+//; # removes beginning space
    say "PLUS!  ($string) remains";
    $task = $string;
  } elsif ($string =~ s/\A$angle//) { # removes the >> from $string
    $string =~ s/\A\s+//; # removes beginning space
    if ($string =~ /$at_team/) {
      $assignee = $+{team};
      $task = $string =~ /\w+@\w+(.+)/;
      say "Assignee is $assignee";
    } elsif ($string =~ /$user_at_team/) {
      ($assignee, $team) = $string =~ s/$user_at_team//;
      say $assignee;
      say $team;
      $team //= "DEFAULT";
      say "ANGLE! ($string) remains; assignee $assignee; team $team";
    }
  } else {
    die "Shit.";
  }

  $string =~ s/\A\s+//;

  say "...now we have to parse ($string)";
}

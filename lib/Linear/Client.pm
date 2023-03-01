use v5.24.0;
use warnings;

package Linear::Client;
use Moose;

use utf8;

# ABSTRACT: a client for Linear, the project management tool

use Cpanel::JSON::XS;
use Future::AsyncAwait;

use Linear::Client::PaginatedResult;

use GraphQL::Miranda;
use IO::Async::Loop;
use Net::Async::HTTP;
use String::Switches;

use experimental 'signatures';

has api_url => (
  is      => 'ro',
  default => q{https://api.linear.app/graphql},
);

has auth_token => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has debug_flogger => (
  is => 'ro',
);

has log_complexity => (
  is => 'rw',
);

sub maybe_log ($self, $arg) {
  my $flogger = $self->debug_flogger;
  return unless $flogger;

  $flogger->log($arg);
}

has _http => (
  is        => 'ro',
  lazy      => 1,
  predicate => 'has_http',
  default   => sub ($self, @) {
    my $loop = IO::Async::Loop->new();
    my $http = Net::Async::HTTP->new(
      notifier_name => 'Linear::Client',
      timeout       => 60,
    );
    $loop->add( $http );

    return $http;
  },
);

sub DEMOLISH ($self, @) {
  $self->_http->remove_from_parent if $self->has_http && $self->_http;
}

# Sure, this is a hack, but it's probably about the right level of
# sophistication/hackiness for the problem at hand.  Here we go:
#
# Cached attributes aren't the hack.  They're fine.  It's a way to say "when
# you ask for a team by key, we'll look in our cached team data.  If we don't
# have that data, or it's out of date, we'll fetch the team data from Linear.
# That means that we're always returning Futures.  All this is fine!
#
# The hack is that we want to have multiple Linear::Client objects that share
# this cache.  First off:  **don't forget** that this means the data needs to
# be things that are equally visible to all users.  If we do know that, then
# it's safe to store the cache in some external storage we've been handed.
# That's what we'll do!  It will let us make one Linear::Client per Synergy
# user, so most GraphQL work is done with the right authz, but they can all
# share locally cached state when appropriate.
#
# We took some notes on a different object structure to make this less hacky,
# but it's going to complicate things, and right now the goal is just to cross
# the finish line.
has _cache_guts => (
  is => 'ro',
  default => sub {  {}  },
);

async sub _get_all_page_nodes ($self, $page_f, $nodes = []) {
  my $page = await $page_f;
  push @$nodes, $page->payload->{nodes}->@*;

  if ($page->has_next_page) {
    return await $self->_get_all_page_nodes(
      $page->next_page,
      $nodes,
    );
  }

  return $nodes;
}

my sub cached_attr ($name, %arg) {
  my $query_name = $arg{query_name};
  Carp::confess("no query_name given") unless $query_name;

  my $query_args = $arg{query_args};
  Carp::confess("no query_args given") unless $query_args;

  my $nodes_select = $arg{nodes_select};
  Carp::confess("no nodes_select given") unless $nodes_select;

  my $node_mapper = $arg{node_mapper};

  my $cache_attr_name = "_$name\_cache";
  my $clearer_name    = "_clear_$cache_attr_name";
  my $plural          = $arg{plural} // "${name}s";

  Sub::Install::install_sub({
    as    => $cache_attr_name,
    code  => sub ($self) {
      my $page_f = $self->do_paginated_query({
        query_name  => $query_name,
        query_args  => $query_args,
        nodes_select => $nodes_select,
      });

      # If we've got a cache entry in the shared state, use that.  Otherwise,
      # make a new entry in it.
      my $guts = $self->_cache_guts;

      my $lookup_f = $self->_get_all_page_nodes($page_f);

      return $guts->{$name} //= {
        cached_at => time,
        # We should allow the query to be a sub that generates things based on
        # client properties, but for now... whatever. -- rjbs, 2021-11-12
        value     => $node_mapper ? $lookup_f->then($node_mapper) : $lookup_f
      };
    }
  });

  Sub::Install::install_sub({
    as    => $clearer_name,
    code  => sub ($self) {
      delete $self->_cache_guts->{$name};
      return;
    },
  });

  Sub::Install::install_sub({
    as    => $plural,
    code  => async sub ($self) {
      my $cache = $self->_cache_guts->{$name};

      return await $cache->{value} if $cache
                                   && time - $cache->{cached_at} < 300
                                   && ! $cache->{value}->is_failed
                                   && ! $cache->{value}->is_cancelled;

      # The value in the cache was no good. Failed, old, I dunno.  Let's clear
      # it and try again. -- rjbs, 2021-11-12

      $self->$clearer_name;
      return await $self->$cache_attr_name->{value};
    },
  });

  Sub::Install::install_sub({
    as    => "lookup_$name",
    code  => async sub ($self, $key) {
      my $dict = await $self->$plural;
      return $dict->{ lc $key };
    }
  });
}

cached_attr project => (
  query_name  => 'projects',
  query_args  => {
    filter => { state => { nin => [ 'completed' ] } },
  },
  nodes_select => [
    qw( id icon name slugId description ),
    teams => [ nodes => [ qw( id key ) ] ],
  ],
  node_mapper => sub ($nodes) {
    my %dict;
    for my $node (@$nodes) {
      $dict{ $node->{slugId} } = $node;
      $node->{teams} = $node->{teams}{nodes};
    }

    return \%dict;
  },
);

cached_attr team => (
  query_name => 'teams',
  query_args => {},
  nodes_select => [
    qw(id key name),
    labels => [ nodes => [ qw( id name color ) ] ],
    states => [ nodes => [ qw( id name color ) ] ],
  ],
  node_mapper => sub ($nodes) {
    return {
      map {; lc $_->{key} => $_ } @$nodes
    }
  },
);

cached_attr user => (
  query_name => 'users',
  query_args => {},
  nodes_select => [ qw( id displayName name ) ],
  node_mapper => sub ($nodes) {
    my $dict = {};

    NODE: for my $node (@$nodes) {
      unless ($node->{displayName}) {
        warn "no display name for $node->{name} // $node->{id}!\n";
        next NODE;
      }

      $dict->{ lc $node->{displayName} } = $node;
    }

    return $dict;
  },
);

async sub fetch_issue ($self, $identifier) {
  my $response = await $self->do_query(
    q[
      query Issue ($id: String!) {
        issue (id: $id) {
          id
          title
          identifier
          createdAt
          updatedAt
          description
          assignee { displayName }
          state { name type id }
          team { key }
          number
          labels { nodes { id name } }
          priority
          url
        }
      }
    ],
    { id => $identifier },
  );

  my $issue = $response->{data}{issue};

  return undef unless $issue;

  $issue->{team} = $issue->{team}{key};
  $issue->{assignee} = $issue->{assignee}{displayName};
  $issue->{labels} = $issue->{labels}{nodes};

  return $issue;
}

my $LINESEP = qr{(
  # space or newlines
  # then three dashes and maybe some leading spaces
  (^|\s+) ---\s*
  |
  \n
)}nxs;

has helper => (
  is => 'ro',
  isa => 'Object',
);

async sub lookup_team_or_user ($self, $string) {
  my $helper   = $self->helper;
  my $username = $helper ? $helper->normalize_username($string) // $string
                         : $string;

  my $team_name = $helper ? $helper->normalize_team_name($string) // $string
                          : $string;

  my ($user, $team) = await Future->needs_all(
    $self->lookup_user($username),
    $self->lookup_team($team_name),
  );

  die "team-or-user name $string is ambiguous" if $user && $team;

  return (user => $user) if $user;
  return (team => $team) if $team;
  return;
}

# Expects '<user>', '<user>@<team>', '<team>'. Returns a
# userid, teamid pair. Either or both may be null
async sub who_or_what ($self, $spec) {
  my $teamname;
  my $username;

  my $helper = $self->helper;

  my ($user, $team);

  if ($spec =~ /\A(\w+)@(\w+)/) {
    # if target is user@team, set user as assignee.
    $username = $1;
    $teamname = $2;

    if ($helper) {
      $username = $helper->normalize_username($username) // $username;
      $teamname = $helper->normalize_team_name($teamname) // $teamname;
    }

    $user = await $self->lookup_user($username);
    die qq{can't find user for "$username"\n} unless $user;

    $team = await $self->lookup_team($teamname);
    die "can't find team for $teamname\n" unless $team;
  } else {
    my ($type, $thing) = await $self->lookup_team_or_user($spec);

    die qq{can't find a user or team for "$spec"\n} unless $type;

    if ($type eq 'user') {
      $user = $thing;
    } elsif ($type eq 'team') {
      $team = $thing;
    } else {
      die "unreachable condition: found something neither team nor user!\n";
    }
  }

  my $assignee_id = $user->{id} if $user;
  my $team_id = $team   ? $team->{id}
              : $helper ? $helper->team_id_for_username($user->{displayName})
              :           undef;

  return ($assignee_id, $team_id);
}

async sub lookup_team_label ($self, $team_key, $label_name) {
  my $team = await $self->lookup_team($team_key);
  my @team_labels = $team->{labels}{nodes}->@*;
  for (@team_labels) {
    if (lc $_->{'name'} eq lc $label_name) {
      return $_->{'id'};
    }
  }
  die "No label $label_name found for team $team_key";
}

async sub lookup_current_cycle_id_for_team_id ($self, $team_id) {
  my $result = await $self->do_query(
    q[
      query CurrentCycle(
        $teamId: ID,
      ) {
        cycles(
          filter: {
            isActive: { eq: true }
            team: { id: { eq: $teamId } }
          }
        ) {
          nodes { id }
        }
      }
    ],
    { teamId => $team_id },
  );

  return $result->{cycles}{nodes}[0]{id};
}

my sub mk_state_cb ($default, $put_in_cycle = 0) {
  my $state_cb = async sub ($self, $issue, $wanted_state) {
    $wanted_state //= $default;
    die "no state name given!\n" unless $wanted_state;

    my $teams   = await $self->teams;
    my $team_id = $issue->{teamId};
    my ($team)  = grep {; $_->{id} eq $team_id } values %$teams;

    die "Something went wrong finding the team!\n" unless $team;

    my ($state) = grep {; lc $_->{name} eq lc $wanted_state }
                  $team->{states}{nodes}->@*;

    die "That team ($team_id) doesn't have a $wanted_state state\n"
      unless $state;

    $issue->{stateId} = $state->{id};

    if ($put_in_cycle) {
      my $cycle_id = await $self->lookup_current_cycle_id_for_team_id($team_id);
      $issue->{cycleId} = $cycle_id;
    }

    return;
  };
}

my sub mk_project_cb () {
  async sub ($self, $issue, $tag) {
    return unless $self->helper;

    my @project_ids = await $self->helper->project_ids_for_tag($tag);

    die "more than one project has the tag ##$tag\n" if @project_ids > 1;
    die "no project has the tag ##$tag\n" if @project_ids == 0;

    my $projects = await $self->projects;

    my ($project) = grep {; $_->{slugId} eq $project_ids[0]
                         || $_->{id}     eq $project_ids[0] } values %$projects;

    unless ($project) {
      die "the tag ##$tag turned into project id $project_ids[0], which can't be found\n";
    }

    unless (grep {; $_->{id} eq $issue->{teamId} } $project->{teams}->@*) {
      die "the target team isn't part of the project ##$tag\n";
    }

    $issue->{projectId} = $project->{id};

    return;
  };
}

my sub mk_label_cb ($default) {
  return async sub ($self, $issue, $label_name) {
    $label_name //= $default;
    die "no label name given!\n" unless $label_name;

    my $teams   = await $self->teams;
    my ($team)  = grep {; $_->{id} eq $issue->{teamId} } values %$teams;

    my @team_labels = $team->{labels}{nodes}->@*;
    for (@team_labels) {
      if (lc $_->{name} eq lc $label_name) {
        $issue->{labelIds} //= [];
        push $issue->{labelIds}->@*, $_->{id};
        return;
      }
    }

    die "couldn't find the label $label_name in this team\n";
  };
}

my sub mk_estimate_cb () {
  state %points_for = (
    xs      => 1,
    s       => 2,
    small   => 2,
    m       => 3,
    medium  => 3,
    l       => 5,
    large   => 5,
    xl      => 8,
  );

  return async sub ($self, $issue, $estimate) {
    die "no estimate size given!\n" unless $estimate;

    my $points = $points_for{ lc $estimate };

    die "unknown estimate size\n" unless $points;

    $issue->{estimate} = $points;

    return;
  };
}

my @FLAG_HANDLER = (
  [ '(!)'     => 'urgent' ],
  [ ':fire:'  => 'urgent' ],
  [ '🔥'      => 'urgent' ],

  [ '(?)'     => 'state', 'To Discuss' ],
  [ ':phone:' => 'state', 'To Discuss' ],
  [ "\N{BLACK TELEPHONE}\N{VARIATION SELECTOR-16}" => 'state', 'To Discuss' ],

  [ qr/##([-0-9a-zA-Z]+)/ => 'project' ],
);

my sub _title_and_flag_switches_for ($line) {
  my @switches;

  my @hunks = split /(\s+)/, $line;
  HUNK: while (defined (my $hunk = pop @hunks)) {
    for my $spec (@FLAG_HANDLER) {
      my ($flag, $switch, $value) = @$spec;
      my $pat = ref $flag ? $flag : quotemeta $flag;

      if ($hunk =~ /\A$pat\z/) {
        push @switches, [ $switch, $1 // $value ];

        # Drop the space that came before this hunk.
        pop @hunks;

        next HUNK;
      }
    }

    push @hunks, $hunk;
    last HUNK;
  }

  return (join(q{}, @hunks), \@switches);
}

my sub _decompose_input ($input) {
  my $description = q{};
  my $switches;

  # set description if given
  if ($input =~ $LINESEP) {
    ($input, my $rest) = split /$LINESEP/, $input, 2;

    my @switch_lines;
    while ($rest && ($rest =~ m{\A$}m || $rest =~ m{\A/})) {
      ((my $next), $rest) = split /$LINESEP/, $rest, 2;
      last unless length $next;

      push @switch_lines, $next;
    }

    if (@switch_lines) {
      ($switches, my $err) = String::Switches::parse_switches(join q{ }, @switch_lines);

      die "problem parsing switches: $err\n" if $err;
    }

    $description = $rest // '';

    # If there is a code block between two sets of three backticks, make sure
    # they are on their own lines
    if ($description =~ /```/) {
      if ($description =~ /`{4}/) {
        die "Don't use more than three backticks in a row! It's confusing.\n";
      }

      # even hunks are non-code-blocks
      # odd  hunks are code blocks
      my @hunks = split /```\n?/, $description;
      s/\n+\z// for @hunks; # Iffy. -- rjbs, 2022-06-14

      $description = q{}; # start with empty string
      for my $i (0 .. $#hunks) {
        $description .= $i % 2 == 0 ? $hunks[$i]
                                    : "```\n$hunks[$i]\n```\n";
      }
    }

    $description =~ s/\n+\z/\n/;
  }

  return ($input, $description, $switches);
}

my %SWITCH_HANDLER = (
  label     => mk_label_cb(undef),
  bug       => mk_label_cb('Bug'),
  chore     => mk_label_cb('Chore'),
  debt      => mk_label_cb('Tech Debt'),
  dev       => mk_label_cb('Feature Dev'),
  standards => mk_label_cb('Standards Work'),

  state   => mk_state_cb(undef),
  done    => mk_state_cb('Done', 1),
  start   => mk_state_cb('In Progress', 1),

  est      => mk_estimate_cb(),
  estimate => mk_estimate_cb(),
  project  => mk_project_cb(),

  urgent  => async sub ($self, $issue, $) { $issue->{priority} = 1 },
);

async sub _extract_target_from_first_line ($self, $issue, $first_line, $helper) {
  state $plusplus = qr{\+\+};
  state $angle    = qr{>>};

  my ($assignee_id, $team_id);
  my $target_err = '';

  # if ++ or if >>
  if ($first_line =~ s/\A$plusplus(?:@(\w+))?\s+//) {
    my $team_name = $1;

    my $auth_user = await $self->get_authenticated_user;

    $assignee_id = $auth_user->{id};
    my $username = $auth_user->{username};

    if ($team_name) {
      my $team = await $self->lookup_team($team_name);
      $team_id = $team->{id};
      $target_err = " (could not determine team)" unless $team_id;
    } else {
      $team_id = $helper
               ? $helper->team_id_for_username($username)
               : undef;

      $target_err = " (could not determine team for $username)" unless $team_id;
    }
  } elsif ($first_line =~ s/\A$angle\s+//) {
    # if >> split into target/input, and assign target accordingly (user, team)
    (my $target, $first_line) = split /\s+/, $first_line, 2;
    $target =~ s/:\z//;

    ($assignee_id, $team_id) = await $self->who_or_what($target);
    $target_err = " (could not determine team for '$target')" unless $team_id;
  } else {
    die "Can't prepare a plan without ++ or >>\n";
  }

  $issue->{teamId}      = $team_id if $team_id;
  $issue->{assigneeId}  = $assignee_id if $assignee_id;

  return ($first_line, $target_err);
}

async sub plan_from_input ($self, $input) {
  my %issue = (
    priority => 0,
  );

  # This object can help us do directory lookups and the like, if provided.
  # -- rjbs, 2021-12-20
  my $helper = $self->helper;

  $input =~ s/\A\s+//; # Trim leading whitespace just in case.

  my ($first_line, $description, $switches) = _decompose_input($input);

  $issue{description} = $description;

  ($first_line, my $target_err) = await $self->_extract_target_from_first_line(\%issue, $first_line, $helper);

  unless ($issue{teamId}) {
    die "can't create plan without team id$target_err\n";
  }

  ($issue{title}, my $flag_switches) = _title_and_flag_switches_for($first_line);

  push @$switches, @$flag_switches;

  for my $switch (@$switches) {
    my ($name, $value) = @$switch;

    my $handler = $SWITCH_HANDLER{lc $name};

    die "unknown switch /$name\n" unless $handler;

    await $handler->($self, \%issue, $value);
  }

  if ($issue{priority} && $issue{priority} == 1 && !$issue{assigneeId}) {
    die "Can't create an urgent issue without a human assignee\n";
  }

  return \%issue;
}

async sub get_authenticated_user ($self) {
  my $user = await $self->do_query(q[
    query Me {
      viewer {
        id
        username: displayName
      }
    }
  ]);

  return $user->{data}{viewer};
}

async sub do_query ($self, $query, $variables = {}, $arg = {}) {
  my $res = await $self->_http->do_request(
    method => 'POST',
    uri    => $self->api_url,
    content_type => 'application/json',
    content      => encode_json({ query => $query, variables => $variables }),
    headers => {
      Authorization => $self->auth_token,
    },
  );

  unless ($res->is_success) {
    warn $res->as_string; # Terrible -- rjbs, 2022-10-06
    die "failure with Linear API";
  }

  if ($self->log_complexity) {
    my $cpx   = $res->header('X-Complexity') // '~';
    my $desc  = $arg->{desc} // 'query';
    warn "$desc: X-Complexity $cpx\n";
  }

  return decode_json($res->decoded_content(charset => undef))
}

async sub create_comment ($self, $comment_data) {
  await $self->do_query(
    q[
      mutation CommentCreateInput (
        $body: String,
        $issueId: String!,
      ) {
        commentCreate(
          input: {
            body: $body
            issueId: $issueId
          }
        ) {
          success
            comment {
              id
              url
           }
         }
      }
    ],
    $comment_data,
  );
}

async sub create_issue ($self, $plan) {
  await $self->do_query(
    q[
      mutation IssueCreate (
        $assigneeId: String,
        $title: String!,
        $description: String,
        $teamId: String!,
        $priority: Int,
        $labelIds: [String!],
        $stateId: String,
        $projectId: String,
        $estimate: Int,
      ) {
        issueCreate (
          input: {
            assigneeId: $assigneeId
            title: $title
            description: $description
            teamId: $teamId
            priority: $priority
            labelIds: $labelIds
            stateId: $stateId
            projectId: $projectId
            estimate: $estimate
          }
        ) {
          success
          issue {
            id
            identifier
            createdAt
            updatedAt
            title
            team { id name }
            priority
            url
          }
        }
      }
    ],
    $plan,
  );
}

async sub post_project_update ($self, $project_id, $arg) {
  await $self->do_query(
    q[
      mutation ProjectUpdateCreate (
        $projectId: String!,
        $body: String,
        $health: ProjectUpdateHealthType,
      ) {
        projectUpdateCreate (
          input: {
            projectId: $projectId
            body: $body
            health: $health
          }
        ) {
          success
        }
      }
    ],
    {
      %$arg,
      projectId => $project_id,
    },
  );
}

async sub search_issues ($self, $search) {
  # The classic LiquidPlanner search buddy behavior here was:
  #   parse search  :  text  -> hunks
  #   compile search:  hunks -> search arguments
  #   execute search:  search arguments -> result
  #
  # Let's start by implementing execute, which *should* help indicate what kind
  # of things need to be in compile and parse anyway.

  # Pagination:
  #   NEXT PAGE:
  #   after : X - cursor id to search after
  #   first : count of items after cursor start (from "after")
  #
  #   PREV PAGE:
  #   before: X - cursor id to search before
  #   last  : count of items before cursor start (from "before")
  #
  #   orderBy: how to sort
  #

  # Issue query filters look like this:
  #   query issues(filter: { assignee: { id: { eq: "$user_id" } } }) {
  #
  # Here, a quick reference on what filters can be sent to an issues query,
  # including only those I think we'll need out of the gate!
  #
  # and: (compound filter)
  # or : (compount filter)
  #
  # assignee    : to whom we have assigned the issue
  # createdAt   : when it was created
  # creator     : who created it
  # cycle       : scheduled when
  # description : issue description contains...
  # dueDate     : when it's due
  # estimate    : issue estimate
  # labels      : labels on issue
  # priority    : issue priority
  # project     : project
  # snoozed*    : (there are filters for snoozing)
  # startedAt   : when work started
  # state       : what state it's in
  # team        : team of the issue
  # title       : issue title contains...
  # updatedAt   : when it was last updated
  state %replace = (
    closed => sub ($closed) {
      return $closed
        ? (state => { type => {  in => [ qw( canceled completed ) ] } })
        : (state => { type => { nin => [ qw( canceled completed ) ] } });
    },
    label => sub ($label) {
      # This is a mess, too... -- rjbs, 2021-12-20
      return (labels => { name => { eq => $label } });
    },
  );

  state %inflate = (
    assignee => sub ($id)   {
      return { id   => { eq => $id    } } if defined $id;
      return { null => Cpanel::JSON::XS::true() };
    },
    priority => sub ($i)    { return { eq => $i } },
    project  => sub ($id)   { return { id   => { eq => $id    } } },
    state    => sub ($name) { return { name => { eq => $name  } } },
    team     => sub ($id)   { return { id   => { eq => $id    } } },
  );

  my %filter;
  KEY: for my $key (keys %$search) {
    if ($replace{$key}) {
      # This is somewhat bold!  What about conflicts? -- rjbs, 2021-12-20
      my %result = $replace{$key}->($search->{$key});
      @filter{ keys %result } = values %result;
      next KEY;
    }

    if (ref $search->{$key}) {
      $filter{$key} = $search->{$key};
      next KEY;
    }

    if ($inflate{$key}) {
      $filter{$key} = $inflate{$key}->($search->{$key});
      next KEY;
    }

    Carp::confess("Don't know what to do with value $search->{$key} for $key");
  }

  $self->maybe_log([ "given search %s built filter %s", $search, \%filter ]);

  my $gen = sub ($pager, @rest) {
    unless (
      @rest == 0
      ||
      @rest == 2 && ($rest[0] eq 'after' || $rest[0] eq 'before')
    ) {
      die "confused! [@rest]";
    }

    # XXX: I am deeply unsure about the byte/text boundary here and will need
    # to think about it with my thinking at on. -- rjbs, 2021-11-19
    my $selection = GraphQL::Miranda->selection_set(
      issues => {
        args    => {
          filter => \%filter,
          first  => 100,
          @rest,
        },
        select  => [
          pageInfo => {
            select => [ qw( startCursor endCursor hasNextPage hasPreviousPage ) ],
          },
          nodes => {
            select => [
              qw(identifier title priority url createdAt updatedAt),
              assignee => [ qw(displayName) ],
              state => [ qw(name type) ],
              team  => [ qw(name id) ],
              project => [ qw(name id icon) ],
            ],
          },
        ],
      },
    );

    return "query {\n" . $selection->as_string("  ") . "\n}\n";
  };

  my $xtract  = sub { $_[0]{data}{issues} };

  my $payload = await $self->do_query($self->$gen);

  return Linear::Client::PaginatedResult->new({
    client  => $self,
    raw_payload     => $payload,
    query_generator => $gen,
    extractor       => $xtract,
  });
}

async sub do_paginated_query ($self, $arg) {
  # query_name, query_args, nodes_select

  my $query_name   = $arg->{query_name};
  my $query_args   = $arg->{query_args};
  my $nodes_select = $arg->{nodes_select};

  my $gen = sub ($pager, @rest) {
    unless (
      @rest == 0
      ||
      @rest == 2 && ($rest[0] eq 'after' || $rest[0] eq 'before')
    ) {
      die "confused! [@rest]";
    }

    # XXX: I am deeply unsure about the byte/text boundary here and will need
    # to think about it with my thinking at on. -- rjbs, 2021-11-19
    my $selection = GraphQL::Miranda->selection_set(
      $query_name => {
        args    => {
          # filter => \%filter,
          first  => 50, # parameterize this?
          %$query_args,
          @rest,
        },
        select  => [
          pageInfo => {
            select => [ qw( startCursor endCursor hasNextPage hasPreviousPage ) ],
          },
          nodes => {
            select => $nodes_select,
          },
        ],
      },
    );

    return "query {\n" . $selection->as_string("  ") . "\n}\n";
  };

  my $xtract  = sub { $_[0]{data}{$query_name} };

  my $payload = await $self->do_query($self->$gen);

  return Linear::Client::PaginatedResult->new({
    client  => $self,
    raw_payload     => $payload,
    query_generator => $gen,
    extractor       => $xtract,
  });
}

no Moose;
1;

package Linear::Client::PaginatedResult;
use Moose;

use Future::AsyncAwait;

use experimental 'signatures';

has client          => (is => 'ro', required => 1); # Linear::Client
has query_generator => (is => 'ro', required => 1); # CodeRef
has extractor       => (is => 'ro', required => 1); # CodeRef

has raw_payload => (is => 'ro', required => 1);

has payload => (
  is => 'ro',
  lazy => 1,
  default => sub ($self, @) {
    $self->extractor->( $self->raw_payload ),
  },
);

sub has_next_page     { $_[0]->payload->{pageInfo}{hasNextPage} }
sub has_previous_page { $_[0]->payload->{pageInfo}{hasPreviousPage} }

async sub next_page ($self) {
  my $payload = $self->payload;

  return undef unless $payload->{pageInfo}{hasNextPage};

  my $result = await $self->client->do_query(
    $self->query_generator->($self, after => $payload->{pageInfo}{endCursor})
  );

  (ref $self)->new({
    client  => $self->client,
    raw_payload => $result,
    query_generator => $self->query_generator,
    extractor => $self->extractor,
  });
}

async sub prev_page ($self) {
  my $payload = $self->payload;

  return undef unless $payload->{pageInfo}{hasPreviousPage};

  my $result = await $self->client->do_query(
    $self->query_generator->($self, before => $payload->{pageInfo}{startCursor})
  );

  (ref $self)->new({
    client  => $self->client,
    raw_payload => $result,
    query_generator => $self->query_generator,
    extractor => $self->extractor,
  });
}

no Moose;
1;

package Zengin::PL::API;

use strict;
use warnings;

use Encode qw(decode_utf8);
use JSON::PP ();
use URI::Escape qw(uri_unescape);

sub new {
    my ($class, %args) = @_;

    return bless {
        backend       => $args{backend},
        backend_class => $args{backend_class} || $ENV{ZENGIN_PL_API_BACKEND_CLASS} || 'Zengin::Pl',
        json          => JSON::PP->new->utf8->canonical->allow_nonref,
    }, $class;
}

sub to_app {
    my ($self) = @_;

    return sub {
        my ($env) = @_;
        return $self->handle_request($env);
    };
}

sub handle_request {
    my ($self, $env) = @_;

    my $method = $env->{REQUEST_METHOD} || 'GET';
    my $path   = $env->{PATH_INFO}      || '/';

    if ($method ne 'GET') {
        return $self->_json_response(405, {
            error => {
                code    => 'method_not_allowed',
                message => 'Only GET is supported',
            },
        });
    }

    if ($path =~ m{\A/api/meta/?\z}) {
        return $self->_handle_meta;
    }

    if ($path =~ m{\A/api/banks/(\d{4})/branches/(\d{3})/?\z}) {
        return $self->_handle_get_branch($1, $2);
    }

    if ($path =~ m{\A/api/banks/(\d{4})/branches/?\z}) {
        return $self->_handle_search_branches($1, $env);
    }

    if ($path =~ m{\A/api/banks/(\d{4})/?\z}) {
        return $self->_handle_get_bank($1);
    }

    if ($path =~ m{\A/api/banks/?\z}) {
        return $self->_handle_search_banks($env);
    }

    return $self->_json_response(404, {
        error => {
            code    => 'not_found',
            message => 'Route not found',
        },
    });
}

sub _handle_get_bank {
    my ($self, $bank_code) = @_;

    my ($bank, $error) = $self->_call_backend('get_bank', $bank_code);
    return $self->_backend_error_response($error) if $error;

    if (!$bank) {
        return $self->_json_response(404, {
            error => {
                code    => 'bank_not_found',
                message => "Bank not found: $bank_code",
            },
        });
    }

    return $self->_json_response(200, {
        bank => $self->_normalize_bank($bank),
    });
}

sub _handle_search_banks {
    my ($self, $env) = @_;

    my $params = $self->_parse_query_string($env->{QUERY_STRING} || q{});
    my $name   = $params->{name};

    if (!defined $name || $name eq q{}) {
        return $self->_json_response(400, {
            error => {
                code    => 'invalid_request',
                message => 'Query parameter "name" is required',
            },
        });
    }

    my ($banks, $error) = $self->_call_backend('search', $name);
    return $self->_backend_error_response($error) if $error;

    $banks ||= [];

    return $self->_json_response(200, {
        banks => [map { $self->_normalize_bank($_) } @{$banks}],
    });
}

sub _handle_get_branch {
    my ($self, $bank_code, $branch_code) = @_;

    my ($bank, $bank_error_response) = $self->_find_bank($bank_code);
    return $bank_error_response if $bank_error_response;

    my ($branch, $error) = $self->_call_backend('get_branch', $bank_code, $branch_code);
    return $self->_backend_error_response($error) if $error;

    if (!$branch) {
        return $self->_json_response(404, {
            error => {
                code    => 'branch_not_found',
                message => "Branch not found: $bank_code/$branch_code",
            },
        });
    }

    return $self->_json_response(200, {
        bank   => $self->_slice_fields($bank, qw(code name)),
        branch => $self->_normalize_branch($branch),
    });
}

sub _handle_search_branches {
    my ($self, $bank_code, $env) = @_;

    my ($bank, $bank_error_response) = $self->_find_bank($bank_code);
    return $bank_error_response if $bank_error_response;

    my $params = $self->_parse_query_string($env->{QUERY_STRING} || q{});
    my $name   = $params->{name};

    if (!defined $name || $name eq q{}) {
        return $self->_json_response(400, {
            error => {
                code    => 'invalid_request',
                message => 'Query parameter "name" is required',
            },
        });
    }

    my ($branches, $error) = $self->_call_backend('search', $bank_code, $name);
    return $self->_backend_error_response($error) if $error;

    $branches ||= [];

    return $self->_json_response(200, {
        bank     => $self->_slice_fields($bank, qw(code name)),
        branches => [map { $self->_slice_fields($_, qw(code name)) } @{$branches}],
    });
}

sub _handle_meta {
    my ($self) = @_;

    my $backend = $self->_backend;
    my $base_url = $self->_backend_base_url($backend);

    return $self->_json_response(200, {
        api => {
            name       => defined $ENV{APP_NAME} ? $ENV{APP_NAME} : 'zengin-pl-api',
            version    => $self->_env_or_undef('APP_VERSION'),
            git_sha    => $self->_env_or_undef('APP_GIT_SHA'),
            build_time => $self->_env_or_undef('APP_BUILD_TIME'),
        },
        backend => {
            class    => $self->{backend_class},
            base_url => $base_url,
        },
        data => {
            source => $base_url,
        },
    });
}

sub _find_bank {
    my ($self, $bank_code) = @_;

    my ($bank, $error) = $self->_call_backend('get_bank', $bank_code);
    return (undef, $self->_backend_error_response($error)) if $error;

    if (!$bank) {
        return (undef, $self->_json_response(404, {
            error => {
                code    => 'bank_not_found',
                message => "Bank not found: $bank_code",
            },
        }));
    }

    return ($bank, undef);
}

sub _call_backend {
    my ($self, $method, @args) = @_;

    my $result = eval {
        my $backend = $self->_backend;
        die sprintf('Backend does not support %s', $method) unless $backend->can($method);
        return $backend->$method(@args);
    };

    return ($result, undef) if !$@;
    return (undef, $@);
}

sub _backend {
    my ($self) = @_;

    return $self->{backend} if $self->{backend};

    my $backend_class = $self->{backend_class};
    eval "require ${backend_class}; 1"
        or die "Failed to load backend ${backend_class}: $@";

    $self->{backend} = $backend_class->can('new')
        ? $backend_class->new
        : $backend_class;

    return $self->{backend};
}

sub _backend_base_url {
    my ($self, $backend) = @_;

    return undef if !defined $backend;

    return $backend->base_url if ref $backend && $backend->can('base_url');
    return $backend->{base_url} if ref $backend eq 'HASH' && exists $backend->{base_url};

    if (ref $backend) {
        my $reftype = ref $backend;
        no strict 'refs';
        return $backend->{base_url} if $reftype && exists $backend->{base_url};
    }

    return $ENV{ZENGIN_PL_BASE_URL} if defined $ENV{ZENGIN_PL_BASE_URL};
    return undef;
}

sub _parse_query_string {
    my ($self, $query_string) = @_;

    my %params;
    for my $pair (grep { length $_ } split /[&;]/, $query_string) {
        my ($key, $value) = split /=/, $pair, 2;
        next if !defined $key || $key eq q{};

        $key   = decode_utf8(uri_unescape($key));
        $value = defined $value ? decode_utf8(uri_unescape($value)) : q{};

        $key   =~ tr/+/ /;
        $value =~ tr/+/ /;

        $params{$key} = $value;
    }

    return \%params;
}

sub _normalize_bank {
    my ($self, $bank) = @_;

    return undef if !defined $bank;

    if (ref $bank eq 'HASH') {
        return { %{$bank} };
    }

    if (ref $bank && $bank->can('TO_JSON')) {
        return $bank->TO_JSON;
    }

    my %normalized;
    for my $field (qw(code name hira kana roma)) {
        next if !ref $bank || !$bank->can($field);
        my $value = $bank->$field;
        $normalized{$field} = $value if defined $value;
    }

    return \%normalized if %normalized;
    return $bank;
}

sub _normalize_branch {
    my ($self, $branch) = @_;

    return $self->_normalize_bank($branch);
}

sub _slice_fields {
    my ($self, $entity, @fields) = @_;

    my $normalized = ref $entity eq 'HASH'
        ? $entity
        : $self->_normalize_bank($entity);

    my %sliced;
    for my $field (@fields) {
        $sliced{$field} = $normalized->{$field}
            if ref $normalized eq 'HASH' && exists $normalized->{$field};
    }

    return \%sliced;
}

sub _env_or_undef {
    my ($self, $name) = @_;
    return defined $ENV{$name} && $ENV{$name} ne q{} ? $ENV{$name} : undef;
}

sub _backend_error_response {
    my ($self, $error) = @_;

    chomp $error;

    return $self->_json_response(500, {
        error => {
            code    => 'backend_error',
            message => $error,
        },
    });
}

sub _json_response {
    my ($self, $status, $payload) = @_;

    my $body = $self->{json}->encode($payload);

    return [
        $status,
        [
            'Content-Type'   => 'application/json; charset=utf-8',
            'Content-Length' => length $body,
        ],
        [$body],
    ];
}

1;

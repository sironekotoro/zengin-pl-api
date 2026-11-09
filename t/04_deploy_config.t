use strict;
use warnings;
use Test::More;

my $workflow_path = '.github/workflows/deploy.yml';
open my $fh, '<', $workflow_path
    or die "Cannot open $workflow_path: $!";
my $workflow = do { local $/; <$fh> };
close $fh;

like(
    $workflow,
    qr/^  MAX_INSTANCES: '3'$/m,
    'Cloud Run maximum instance count is explicit and conservative',
);

like(
    $workflow,
    qr/^          flags: '--max=\$\{\{ env\.MAX_INSTANCES \}\}'$/m,
    'deploy action applies the service-level maximum instance count',
);

my $build_pos = index($workflow, 'name: Build image');
my $auth_pos = index($workflow, '- id: auth');
ok($build_pos >= 0, 'Docker build marker exists');
ok($auth_pos >= 0, 'cloud auth marker exists');
ok($build_pos >= 0 && $auth_pos >= 0 && $build_pos < $auth_pos,
    'cloud credentials are created only after Docker build');
open my $ignore_fh, '<', '.dockerignore' or die $!;
my $ignore = do { local $/; <$ignore_fh> };
like($ignore, qr/^gha-creds-\*\.json$/m, 'root cloud credentials excluded from Docker context');
like($ignore, qr/^\*\*\/gha-creds-\*\.json$/m, 'nested cloud credentials excluded from Docker context');
like($workflow, qr/commit_sha:/, 'reusable deployment accepts an explicit commit SHA');
like($workflow, qr/group: deploy-production/, 'deployment paths share one concurrency group');
done_testing;


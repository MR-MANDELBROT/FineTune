#!/usr/bin/perl
# Loads FineTune's MediaRemote bridge and invokes one of its functions.
#
# The only reason this script exists: MediaRemote answers Apple-signed binaries
# but not third-party apps, and /usr/bin/perl is Apple-signed. Loading the
# bridge here is what makes the framework respond at all.
#
# Usage: /usr/bin/perl nowplaying.pl <path-to-dylib> get
#        /usr/bin/perl nowplaying.pl <path-to-dylib> toggle [expected-bundle-id]

use strict;
use warnings;
use DynaLoader;

sub fail {
    print STDERR "$_[0]\n";
    exit 1;
}

my $library = shift @ARGV or fail "Missing library path";
my $command = shift @ARGV or fail "Missing command";

# Optional for "toggle": the bundle identifier the caller expects to be playing.
# The bridge drops the command if the now playing session has moved on since.
my $expected = shift @ARGV;
$ENV{FINETUNE_EXPECTED_BUNDLE} = $expected if defined $expected;

fail "Too many arguments" if @ARGV;
fail "Library not found at $library" unless -e $library;

my %symbols = (
    get    => "finetune_nowplaying_get",
    toggle => "finetune_nowplaying_toggle",
);
my $symbol_name = $symbols{$command} or fail "Unknown command: $command";

my $handle = DynaLoader::dl_load_file($library, 0)
  or fail "Failed to load library: $library";
my $symbol = DynaLoader::dl_find_symbol($handle, $symbol_name)
  or fail "Symbol '$symbol_name' not found in $library";

DynaLoader::dl_install_xsub("main::$command", $symbol);

eval {
    no strict "refs";
    &{"main::$command"}();
};
fail "Error executing $command: $@" if $@;

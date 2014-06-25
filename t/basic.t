use strict;
use warnings;

use Data::Transform::ExplicitMetadata qw(encode decode);

use Scalar::Util;
use Test::More tests => 34;

test_scalar();
test_simple_references();
test_filehandle();
test_coderef();
test_refref();
test_regex();
test_vstring();

sub test_scalar {
    my $tester = sub {
        my($original, $desc) = @_;
        my $encoded = encode($original);
        is($encoded, $original, "encode $desc");
        my $decoded = decode($encoded);
        is($decoded, $original, "decode $desc");
    };

    $tester->(1, 'number');
    $tester->('a string', 'string');
    $tester->('', 'empty string');
    $tester->(undef, 'undef');
}

sub test_simple_references {
    my %tests = (
        scalar => \'a scalar',
        array  => [ 1,2,3 ],
        hash   => { one => 1, two => 2, string => 'a string' }
    );
    foreach my $test ( keys %tests ) {
        my $original = $tests{$test};
        my $encoded = encode($original);

        my $expected = {
            __value => ref($original) eq 'SCALAR' ? $$original : $original,
            __reftype => Scalar::Util::reftype($original),
            __refaddr => Scalar::Util::refaddr($original),
        };
        $expected->{__blesstype} = Scalar::Util::blessed($original) if Scalar::Util::blessed($original);

        is_deeply($encoded, $expected, "encode $test");

        my $decoded = decode($encoded);
        is_deeply($decoded, $original, "decode $test");
    }
}

sub test_filehandle {
    open(my $filehandle, __FILE__) || die "Can't open file: $!";

    my $encoded = encode($filehandle);
    my $decoded = decode($encoded);

    ok(delete $encoded->{__value}->{SCALAR}->{__refaddr},
        'anonymous scalar has __refaddr');

    my $expected = {
        __value => {
            PACKAGE => 'main',
            NAME => '$filehandle',
            IO => fileno($filehandle),
            IOseek => '0 but true',
            SCALAR => {
                __value => undef,
                __reftype => 'SCALAR',
            },
        },
        __reftype => 'GLOB',
        __refaddr => Scalar::Util::refaddr($filehandle),
    };

    is_deeply($encoded, $expected, 'encode filehandle');

    is(fileno($decoded), fileno($filehandle), 'decode filehandle');


    # try with a bare filehandle
    $encoded = encode(*STDOUT);
    $decoded = decode($encoded);

    ok(delete $encoded->{__value}->{SCALAR}->{__refaddr},
        'anonymous scalar has __refaddr');

    $expected = {
        __value => {
            PACKAGE => 'main',
            NAME => 'STDOUT',
            IO => fileno(STDOUT),
            IOseek => undef,
            SCALAR => {
                __value => undef,
                __reftype => 'SCALAR',
            },
        },
        __reftype => 'GLOB',
    };
    is_deeply($encoded, $expected, 'encode bare filehandle');
    is(ref(\$decoded), 'GLOB', 'decoded bare filehandle type');
    is(fileno($decoded), fileno(STDOUT), 'decode bare filehandle fileno');
}

sub test_coderef {
    my $original = sub { 1 };

    my $encoded = encode($original);

    my $expected = {
        __value => "$original",
        __reftype => 'CODE',
        __refaddr => Scalar::Util::refaddr($original),
    };

    is_deeply($encoded, $expected, 'encode coderef');

    my $decoded = decode($encoded);
    is(ref($decoded), 'CODE', 'decoded to a coderef');
}

sub test_refref {
    my $hash = { };
    my $original = \$hash;

    my $expected = {
        __reftype => 'REF',
        __refaddr => Scalar::Util::refaddr($original),
        __value => {
            __reftype => 'HASH',
            __refaddr => Scalar::Util::refaddr($hash),
            __value => { }
        }
    };
    my $encoded = encode($original);
    is_deeply($encoded, $expected, 'encode ref reference');

    my $decoded = decode($encoded);
    is_deeply($decoded, $original, 'decode ref reference');
}

sub test_regex {
    my $original = qr(a regex \w)m;

    my $expected = {
        __reftype => 'REGEXP',
        __refaddr => Scalar::Util::refaddr($original),
        __value => [ 'a regex \w', 'm' ],
    };
    my $encoded = encode($original);
    is_deeply($encoded, $expected, 'encode regex');

    my $decoded = decode($encoded);
    is("$decoded", "$original", 'decode regex');
    isa_ok($decoded, 'Regexp');
}

sub test_vstring {
    my $original = v1.2.3.4;

    my $expected = {
        __reftype => 'VSTRING',
        __value => [ 1, 2, 3, 4 ],
    };
    my $encoded = encode($original);
    is_deeply($encoded, $expected, 'encode vstring');

    my $decoded = decode($encoded);
    is($decoded, $original, 'decode vstring');
    is(ref(\$decoded),
        $^V ge v5.10.0 ? 'VSTRING' : 'SCALAR',
        'ref to decoded');


    my $vstring = v1.2.3.4;
    $original = \$vstring;
    $expected->{__refaddr} = Scalar::Util::refaddr($original);
    $encoded = encode($original);
    is_deeply($encoded, $expected, 'encode vstring ref');

    $decoded = decode($encoded);
    is($$decoded, $$original, 'decode vstring ref');
    is(ref($decoded),
        $^V ge v5.10.0 ? 'VSTRING' : 'SCALAR',
        'decoded ref');
}

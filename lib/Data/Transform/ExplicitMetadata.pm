package Data::Transform::ExplicitMetadata;

use strict;
use warnings;

use Scalar::Util;
use Symbol;
use Carp;

our $VERSION = "0.03";

use base 'Exporter';

our @EXPORT_OK = qw( encode decode );

our $HAS_FMODE;
BEGIN {
    $HAS_FMODE = eval { require FileHandle::Fmode } || '';
}

sub _get_open_mode {
    my $fh = shift;
    if (! FileHandle::Fmode::is_FH($fh)) {
        return undef;
    }

    if (FileHandle::Fmode::is_RO($fh)) {
        return '<';

    } elsif (FileHandle::Fmode::is_WO($fh)) {
        if (FileHandle::Fmode::is_A($fh)) {
            return '>>';
        } else {
            return '>';
        }

    } elsif (FileHandle::Fmode::is_A($fh)) {
        return '+>>'

    } else {
        return '+<'
    }
}

sub encode {
    my $value = shift;
    my $path_expr = shift;
    my $seen = shift;

    if (!ref($value)) {
        my $ref = ref(\$value);
        # perl 5.8 - ref() with a vstring returns SCALAR
        if ($ref eq 'GLOB'
            or
            $ref eq 'VSTRING' or Scalar::Util::isvstring($value)
        ) {
            $value = encode(\$value, $path_expr, $seen);
            delete $value->{__refaddr};
        }
        return $value;
    }

    $path_expr ||= '$VAR';
    $seen ||= {};

    if (ref $value) {
        my $reftype     = Scalar::Util::reftype($value);
        my $refaddr     = Scalar::Util::refaddr($value);
        my $blesstype   = Scalar::Util::blessed($value);

        if ($seen->{$value}) {
            my $rv = {  __reftype => $reftype,
                        __refaddr => $refaddr,
                        __recursive => 1,
                        __value => $seen->{$value} };
            $rv->{__blessed} = $blesstype if $blesstype;
            return $rv;
        }
        $seen->{$value} = $path_expr;

        # Build a new path string for recursive calls
        my $_p = sub {
            return join('', '${', $path_expr, '}') if ($reftype eq 'SCALAR' or $reftype eq 'REF');
            return join('', '*{', $path_expr, '}') if ($reftype eq 'GLOB');

            my @bracket = $reftype eq 'ARRAY' ? ( '[', ']' ) : ( '{', '}' );
            return sprintf('%s->%s%s%s', $path_expr, $bracket[0], $_, $bracket[1]);
        };

        if (my $tied = _is_tied($value)) {
            local $_ = 'tied';  # &$_p needs this
            my $original = encode(_untie_and_get_original_value($value), &$_p, $seen);
            my $rv = {  __reftype => $reftype,
                        __refaddr => $refaddr,
                        __tied    => ref($original) ? $original->{__value} : $original,
                        __value   => encode($tied, &$_p, $seen) };
            _retie($value, $tied);
            $rv->{__blessed} = $blesstype if $blesstype;
            return $rv;
        }

        if ($reftype eq 'HASH') {
            $value = { map { $_ => encode($value->{$_}, &$_p, $seen) } sort(keys %$value) };

        } elsif ($reftype eq 'ARRAY') {
            $value = [ map { encode($value->[$_], &$_p, $seen) } (0 .. $#$value) ];

        } elsif ($reftype eq 'GLOB') {
            my %tmpvalue = map { $_ => encode(*{$value}{$_},
                                            &$_p."{$_}",
                                            $seen) }
                           grep { *{$value}{$_} }
                           qw(HASH ARRAY SCALAR);
            @tmpvalue{'NAME','PACKAGE'} = (*{$value}{NAME}, *{$value}{PACKAGE});
            if (*{$value}{CODE}) {
                $tmpvalue{CODE} = encode(*{$value}{CODE}, &$_p, $seen);
            }
            if (*{$value}{IO}) {
                if( $tmpvalue{IO} = encode(fileno(*{$value}{IO}), &$_p, $seen) ) {
                    $tmpvalue{IOmode} = _get_open_mode(*{$value}{IO}) if $HAS_FMODE;
                    $tmpvalue{IOseek} = sysseek($value, 0, 1);
                }
            }
            $value = \%tmpvalue;
        } elsif (($reftype eq 'REGEXP')
                    or ($reftype eq 'SCALAR' and defined($blesstype) and $blesstype eq 'Regexp')
        ) {
            $reftype = 'REGEXP';
            undef($blesstype) unless $blesstype ne 'Regexp';
            my($pattern, $modifiers);
            if ($^V ge v5.9.5) {
                require re;
            }
            if (defined &re::regexp_pattern) {
                ($pattern, $modifiers) = re::regexp_pattern($value);
            } else {
                $value = "$value";
                ($modifiers, $pattern) = $value =~ m/\(\?(\w*)-\w*:(.*)\)$/;
            }
            $value = [ $pattern, $modifiers ];
        } elsif ($reftype eq 'CODE') {
            (my $copy = $value.'') =~ s/^(\w+)\=//;  # Hack to change CodeClass=CODE(0x123) to CODE=(0x123)
            $value = $copy;
        } elsif ($reftype eq 'REF') {
            $value = encode($$value, &$_p, $seen );
        } elsif (($reftype eq 'VSTRING') or (ref($value) eq 'SCALAR' and Scalar::Util::isvstring($$value))) {
            $reftype = 'VSTRING';
            $value = [ unpack('c*', $$value) ];
        } elsif ($reftype eq 'SCALAR') {
            $value = encode($$value, &$_p, $seen);
        }

        $value = { __reftype => $reftype, __refaddr => $refaddr, __value => $value };
        $value->{__blessed} = $blesstype if $blesstype;
    }

    return $value;
}

sub _is_tied {
    my $ref = shift;

    my $reftype = Scalar::Util::reftype($ref);
    my $tied;
    if    ($reftype eq 'HASH')   { $tied = tied %$ref }
    elsif ($reftype eq 'ARRAY')  { $tied = tied @$ref }
    elsif ($reftype eq 'SCALAR') { $tied = tied $$ref }
    elsif ($reftype eq 'GLOB')   { $tied = tied *$ref }

    return $tied;
}

sub _untie_and_get_original_value {
    my $ref = shift;

    my $tied_val = _is_tied($ref);
    my $class = Scalar::Util::blessed($tied_val);
    my $untie_function = join('::', $class, 'UNTIE');
    no strict 'refs';
    local *$untie_function = sub { };
    use strict 'refs';

    my $reftype = Scalar::Util::reftype($ref);
    my $original;
    if (!$reftype) {
        untie $ref;
        $original = $ref;
    } elsif ($reftype eq 'SCALAR') {
        untie $$ref;
        $original = $$ref;
    } elsif ($reftype eq 'ARRAY') {
        untie @$ref;
        $original = [ @$ref ];
    } elsif ($reftype eq 'HASH') {
        untie %$ref;
        $original = { %$ref };
    } elsif ($reftype eq 'GLOB') {
        untie *$ref;
        my $pkg = *$ref{PACKAGE};
        my $name = *$ref{NAME};
        $original = _create_anon_ref_of_type('GLOB', $pkg, $name);
        *$original = *$ref;
    } else {
        Carp::croak("Cannot retrieve the original value of a tied $reftype");
    }
    return $original;
}

sub _retie {
    my($ref, $value) = @_;

    my $reftype = Scalar::Util::reftype($ref);
    my $class = Scalar::Util::blessed($value);
    no strict 'refs';
    no warnings 'redefine';
    if ($reftype eq 'SCALAR') {
        my $tiescalar = join('::',$class, 'TIESCALAR');
        local *$tiescalar = sub { return $value };
        tie $$ref, $class;

    } elsif ($reftype eq 'ARRAY') {
        my $tiearray = join('::', $class, 'TIEARRAY');
        local *$tiearray = sub { return $value };
        tie @$ref, $class;

    } elsif ($reftype eq 'HASH') {
        my $tiehash = join('::', $class, 'TIEHASH');
        local *$tiehash = sub { return $value };
        tie %$ref, $class;

    } elsif ($reftype eq 'GLOB') {
        my $tiehandle = join('::', $class, 'TIEHANDLE');
        local *$tiehandle = sub { return $value };
        tie *$ref, $class;

    } else {
        Carp::croak('Cannot recreate a tied '.scalar(ref $value));
    }
}

sub _create_anon_ref_of_type {
    my($type, $package, $name) = @_;

    if ($type eq 'SCALAR') {
        my $anon;
        return \$anon;
    } elsif ($type eq 'ARRAY') {
        return [];
    } elsif ($type eq 'HASH') {
        return {};
    } elsif ($type eq 'GLOB') {
        my $rv;
        if ($package and $name
            and
            $package ne 'Symbol'
            and
            $name !~ m/GEN\d/
        ) {
            my $globname = join('::',$package, $name);
            $rv = do { no strict 'refs'; local *$globname; \*$globname; };
        } else {
            $rv = Symbol::gensym();
        }
        return $rv;
    }
}

sub _recreate_fh {
    my($fileno, $mode) = @_;

    my $fh;
    if ($mode) {
        open($fh, $mode . '&=', $fileno)
            || Carp::carp("Couldn't open filehandle for descriptor $fileno with mode $mode: $!");

    } else {
        open($fh, '>&=', $fileno)
        || open($fh, '<&=', $fileno)
        || Carp::carp("Couldn't open filehandle for descriptor $fileno: $!");
    }
    return $fh;
}

sub decode {
    my($input, $recursive_queue, $recurse_fill) = @_;

    unless (ref $input) {
        return $input;
    }

    _validate_decode_structure($input);

    my($value, $reftype, $refaddr, $blessed) = @$input{'__value','__reftype','__refaddr','__blessed'};
    my $rv;
    my $is_first_invocation = ! $recursive_queue;
    $recursive_queue ||= [];

    if ($input->{__recursive}) {
        my $path = $input->{__value};
        push @$recursive_queue,
            sub {
                my $VAR = shift;
                $recurse_fill->(eval $path);
            };

    } elsif ($input->{__tied}) {
        $rv = _create_anon_ref_of_type($reftype);
        my $tied_value;
        $tied_value = decode($value, $recursive_queue, sub { $tied_value });
        _retie($rv, $tied_value);

    } elsif ($reftype eq 'SCALAR') {
        $rv = \$value;

    } elsif ($reftype eq 'ARRAY') {
        $rv = [];
        for (my $i = 0; $i < @$value; $i++) {
            my $idx = $i;
            push @$rv, decode($value->[$i], $recursive_queue, sub { $rv->[$idx] = shift });
        }

    } elsif ($reftype eq 'HASH') {
        $rv = {};
        foreach my $key ( sort keys %$value ) {
            my $k = $key;
            $rv->{$key} = decode($value->{$key}, $recursive_queue, sub { $rv->{$k} = shift });
        }

    } elsif ($reftype eq 'GLOB') {
        my $is_real_glob = ($value->{PACKAGE} ne 'Symbol'
                            and $value->{NAME} !~ m/^GEN\d+/
                            and $value->{NAME} =~ m/^\w/);
        $rv = _create_anon_ref_of_type('GLOB', $value->{PACKAGE}, $value->{NAME});

        foreach my $type ( keys %$value ) {
            next if ($type eq 'NAME' or $type eq 'PACKAGE' or $type eq 'IOseek' or $type eq 'IOMode');
            if ($type eq 'IO') {
                if (my $fileno = $value->{IO}) {
                    $rv = _recreate_fh($fileno, $value->{IOMode});
                }
            } elsif ($type eq 'CODE') {
                *{$rv} = \&_dummy_sub unless ($is_real_glob);

            } else {
                *{$rv} = decode($value->{$type}, $recursive_queue, sub { *{$rv} = shift });
            }
        }

        $rv = *$rv unless $refaddr;

    } elsif ($reftype eq 'CODE') {
        $rv = \&_dummy_sub;

    } elsif ($reftype eq 'REF') {
        my $ref;
        $ref = decode($value, $recursive_queue, sub { $ref = shift });
        $rv = \$ref;

    } elsif ($reftype eq 'REGEXP') {
        my($pattern,$modifiers) = @$value[0,1];
        $rv = eval "qr($pattern)$modifiers";

    } elsif ($reftype eq 'VSTRING') {
        my $vstring = eval 'v' . join('.', @$value);
        $rv = $refaddr ? \$vstring : $vstring;

    }

    bless $rv, $blessed if ($blessed and ! $input->{__recursive});

    if ($is_first_invocation) {
        $_->($rv) foreach @$recursive_queue;
    }

    return $rv;
}

sub _dummy_sub {
    'Put in place by ' . __PACKAGE__ . ' when it could not find the named sub';
}

sub _validate_decode_structure {
    my $input = shift;

    ref($input) eq 'HASH'
        or Carp::croak('Invalid decode data: expected hashref but got '.ref($input));

    exists($input->{__value})
        or Carp::croak('Invalid decode data: expected key __value');
    exists($input->{__reftype})
        or Carp::croak('Invalid decode data: expected key __reftype');

    my($reftype, $value, $blesstype) = @$input{'__reftype','__value','__blesstype'};
    $reftype eq 'GLOB'
        or $reftype eq 'VSTRING'
        or exists($input->{__refaddr})
        or Carp::croak('Invalid decode data: expected key __refaddr');

    ($blesstype and $reftype)
        or !$blesstype
        or Carp::croak('Invalid decode data: Cannot have __blesstype without __reftype');

    my $compatible_references =
            (   ( $reftype eq 'SCALAR' and ! ref($value) )
                or
                ( $reftype eq ref($value) )
                or
                ( $reftype eq 'GLOB' and exists($value->{SCALAR}))
                or
                ( $reftype eq 'CODE' and $value and ref($value) eq '' )
                or
                ( $reftype eq 'REF' and ref($value) eq 'HASH' and exists($value->{__reftype}) )
                or
                ( $reftype eq 'REGEXP' and ref($value) eq 'ARRAY' )
                or
                ( $reftype eq 'VSTRING' and ref($value) eq 'ARRAY' )
                or
                ( $reftype and ! ref($input->{__value}) and $input->{__recursive} )
                or
                ( $input->{__tied} and ref($input->{__value}) and $input->{__value}->{__blessed} )
            );
    $compatible_references or Carp::croak('Invalid decode data: __reftype is '
                        . $input->{__reftype}
                        . ' but __value is a '
                        . ref($input->{__value}));
    return 1;
}

1;

=pod

=head1 NAME

Data::Transform::ExplicitMetadata - Encode Perl values in a json-friendly way

=head1 SYNOPSIS

  use Data::Transform::ExplicitMetadata qw(encode decode);
  use JSON;

  my $val = encode($some_data_structure);
  $io->print( JSON::encode_json( $val ));

  my $data_structure_copy = decode($val);

=head1 DESCRIPTION

Transforms an arbitrarily nested data structure into an analogous data
structure composed of only simple scalars, arrayrefs and hashrefs that may
be safely JSON-encoded, while retaining all the Perl-specific metadata
about typeglobs, blessed and tied references, self-referential data,
reference addresses, etc.

With a few exceptions, a copy of the original data structure can be recreated
from the encoded version.

=head2 Functions

=over 4

=item encode

Accepts a single value and returns a value that may be safely passed to
JSON::encode_json().  encode_json() cannot handle Perl-specific data like
blessed references or typeglobs.  Non-reference scalar values like numbers
and strings are returned unchanged.  For all references, encode()
returns a hashref with these keys
  __reftype     String indicating the type of reference, as
                  returned by Scalar::Util::reftype()
  __refaddr     Memory address of the reference, as returned by
                  Scalar::Util::refaddr()
  __blessed     Package this reference is blessed into, as returned
                  by Scalar::Util::blessed.
  __value       Reference to the unblessed data.
  __tied        The original value hidden by the tie() operation.
  __recursive   Flag indicating this reference was seen before

If the reference was not blessed or tied, then the __blessed and/or __tied keys
will not be present.

__value is generally a copy of the underlying data.  For example, if the input
value is an hashref, then __value will also be a hashref containing the input
value's kays and values.  For typeblobs and glob refs, __value will be a
hashref with the keys NAME, PACKAGE, SCALAR, ARRAY, HASH, IO and CODE.  For
compiled regexps, __value will be a 2-element arrayref of the pattern and
modifiers.  For coderefs, __value will be the stringified reference, like
"CODE=(0x12345678)".  For v-strings and v-string refs, __value will by an
arrayref containing the integers making up the v-string.

For tied objects, __tied will be contain the original value hidden by tie()
and __value will contain the tied data.  The original data is retrieved by:
    * call tied() to get a copy of the tied data
    * localize the UNTIE method in the appropriate class
    * untie the variable
    * save a copy of the original value
    * localize the appropriate TIE* mythod to return the tied data
    * call tie() to retie the variable

if __recursive is true, then __value will contain a string representation
of the first place this reference was seen in the data structure.

encode() handles arbitrarily nested data structures, meaning that
values in the __values slot may also be encoded this way.

=item deocde

Accepts a single value and returns a copy of the data structure originally
passed to encode().  __refaddr information is discarded and new copies of
nested data structures is created.  Self-referential data is re-linked to the
appropriate placxe in the new copy.  Blessed references are re-bless into
the original packages.

Tied variables are re-tied by localizing the appropriate TIE* method to return
the tied data.  The variable's original data is filled in before calling tie().

The IO slot of typeglobs is recreated by opening the handle with the same
descriptor number.  If the module FileHandle::Fmode is available, it will be
re-opened in the same mode as the original.  Otherwise, it will first try
re-opening the file descriptor in read mode, then write mode.

Coderefs cannot be decoded properly.  They are recreated by returning a
reference to a dummy sub that returns a message explaning the situation.

=back

=head1 SEE ALSO

L<JSON>, L<Sereal>, L<Data::Dumper>, L<FileHandle::Fmode>

=head1 AUTHOR

Anthony Brummett <brummett@cpan.org>

=head1 COPYRIGHT

Copyright 2014, Anthony Brummett.  This module is free software. It may
be used, redistributed and/or modified under the same terms as Perl itself.

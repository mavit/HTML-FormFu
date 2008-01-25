use strict;
use warnings;

use Test::More tests => 7;

use HTML::FormFu::MultiPage;
use Crypt::CBC ();
use Storable qw/ thaw /;
use YAML::Syck qw/ LoadFile /;

my $yaml_file = 't/multipage-no-combine/multipage.yml';

my $multi = HTML::FormFu::MultiPage->new;

$multi->load_config_file( $yaml_file );

$multi->process({
    foo    => 'abc',
    submit => 'Submit',
});

ok( $multi->current_form->submitted_and_valid );

like( "$multi", qr|<input name="bar" type="text" />| );

# internals alert!
# decrypt the hidden value, and check it contains the expected data

my $page2 = $multi->next_form;

my $value = $page2->get_field({ name => 'crypt' })->default;

my $yaml = LoadFile( $yaml_file );

my $cbc = Crypt::CBC->new( %{ $yaml->{crypt_args} } );

my $decrypted = $cbc->decrypt_hex( $value );

my $data = thaw( $decrypted );

is( $data->{current_page}, 1 );

ok( grep { $_ eq 'foo' }    @{ $data->{valid_names} } );
ok( grep { $_ eq 'submit' } @{ $data->{valid_names} } );

is( $data->{params}{foo},    'abc' );
is( $data->{params}{submit}, 'Submit' );


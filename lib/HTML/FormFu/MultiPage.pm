package HTML::FormFu::MultiPage;
use strict;

use HTML::FormFu;
use HTML::FormFu::Attribute qw/
    mk_attrs mk_attr_accessors
    mk_inherited_accessors mk_output_accessors
    mk_inherited_merging_accessors mk_accessors /;
use HTML::FormFu::ObjectUtil qw/
    populate load_config_file form
    clone stash parent
    get_nested_hash_value set_nested_hash_value /;

use HTML::FormFu::FakeQuery;
use Carp qw/ croak /;
use Crypt::CBC;
use Perl6::Junction qw/ any /;
use Scalar::Util qw/ blessed /;
use Storable qw/ dclone nfreeze thaw /;

use overload
    'eq' => sub { refaddr $_[0] eq refaddr $_[1] },
    'ne' => sub { refaddr $_[0] ne refaddr $_[1] },
    '==' => sub { refaddr $_[0] eq refaddr $_[1] },
    '!=' => sub { refaddr $_[0] ne refaddr $_[1] },
    '""' => sub { return shift->render },
    bool => sub {1},
    fallback => 1;

__PACKAGE__->mk_attrs(qw/ attributes crypt_args /);

__PACKAGE__->mk_attr_accessors(qw/ id action enctype method /);

our @ACCESSORS = qw/
    indicator filename javascript javascript_src
    element_defaults query_type languages force_error_message
    localize_class tt_module
    nested_name nested_subscript model_class
    auto_fieldset
/;

__PACKAGE__->mk_accessors(
    @ACCESSORS, 
    qw/ query pages _current_page current_form complete
        multipage_hidden_name combine_params /
);

__PACKAGE__->mk_output_accessors(qw/ form_error_message /);

our @INHERITED_ACCESSORS = qw/
    auto_id auto_label auto_error_class auto_error_message
    auto_constraint_class auto_inflator_class auto_validator_class
    auto_transformer_class
    render_method render_processed_value force_errors repeatable_count
/;

__PACKAGE__->mk_inherited_accessors( @INHERITED_ACCESSORS );

our @INHERITED_MERGING_ACCESSORS = qw/ tt_args config_callback /;

__PACKAGE__->mk_inherited_merging_accessors( @INHERITED_MERGING_ACCESSORS );

*loc = \&localize;

Class::C3::initialize();

sub new {
    my $class = shift;

    my %attrs;
    eval { %attrs = %{ $_[0] } if @_ };
    croak "attributes argument must be a hashref" if $@;

    my $self = bless {}, $class;

    my %defaults = (
        stash              => {},
        element_defaults   => {},
        tt_args            => {},
        languages          => ['en'],
        combine_params     => 1,
        multipage_hidden_name => '_multipage_field',
    );

    $self->populate( \%defaults );

    $self->populate( \%attrs );

    return $self;
}

sub process {
    my $self = shift;

    my $query;
    my $input;
    
    if (@_) {
        $query = shift;
        $self->query($query);
    }
    else {
        $query = $self->query;
    }
    
    if ( defined $query && blessed($query) ) {
        $input = $query->param( $self->multipage_hidden_name );
    }
    elsif ( defined $query ) {
        # it's not an object, just a hashref
        
        $input = $self->get_nested_hash_value(
            $query, $self->multipage_hidden_name
        );
    }
    
    my $data = $self->_process_get_data( $input );
    my $current_page;
    my @pages;
    
    eval { @pages = @{ $self->pages } };
    croak "pages() must be an arrayref" if $@;
    
    if ( defined $data ) {
        $current_page = $data->{current_page};
        
        my $current_form = $self->_load_current_form( $current_page, $data );
        
        # are we on the last page?
        # are we complete?
        
        if ( ( $current_page == $#pages ) 
            && $current_form->submitted_and_valid )
        {
            $self->complete(1);
        }
    }
    else {
        # default to first page
        
        $self->_load_current_form( 0 );
    }
    
    #
    
#    return $form->process( defined $query ? $query : () );
}

sub _process_get_data {
    my ( $self, $input ) = @_;
    
    return unless defined $input && length $input;
    
    my $crypt = Crypt::CBC->new(
        %{ $self->crypt_args }
    );
    
    my $data;
    
    eval { $data = $crypt->decrypt_hex( $input ) };
    
    if ( defined $data ) {
        $data = thaw( $data );
    }
    else {
        # should handle errors better
        
        $data = undef;
    }
    
    return $data;
}

sub _load_current_form {
    my ( $self, $current_page, $data ) = @_;
    
    my $current_form = HTML::FormFu->new;
    
    my $current_data = dclone( $self->pages->[ $current_page ] );
    
    for my $key (
        @ACCESSORS,
        @INHERITED_ACCESSORS,
        @INHERITED_MERGING_ACCESSORS )
    {
        my $value = $self->$key;
        
        $current_form->$key( $value )
            if defined $value;
    }
    
    my $attrs = $self->attrs;
    
    for my $key ( keys %$attrs ) {
        $current_form->$key( $attrs->{$key} );
    }
    
    $current_form->populate( $current_data );
    
    $current_form->query( $self->query );
    $current_form->process;
    
    if ( defined $data && $self->combine_params ) {
        
        for my $name ( @{ $data->{valid_names} } ) {
            
            my $value = $self->get_nested_hash_value(
                $data->{params}, $name );
            
            $current_form->add_valid( $name, $value );
        }
    }
    
    $self->_current_page( $current_page );
    $self->current_form( $current_form );
    
    return $current_form;
}

sub render {
    my $self = shift;
    
    my $form = $self->current_form;
    
    croak "process() must be called before render()"
        if !defined $form;
    
    if ( $self->complete ) {
        # why would you render if it's complete?
        # anyway, just show the last page
        
        return $form->render(@_);
    }
    
    if ( $form->submitted_and_valid ) {
        # return the next page
        
        return $self->next_form->render(@_);
    }
    
    # return the current page
    
    return $form->render(@_);
}

sub next_form {
    my ( $self ) = @_;
    
    my $form = $self->current_form;
    
    croak "process() must be called before next_page()"
        if !defined $form;
    
    my $current_page = $self->_current_page;
    my $page_data    = dclone( $self->pages->[ $current_page + 1 ] );
    
    my $next_form = HTML::FormFu->new;
    
    for my $key (
        @ACCESSORS,
        @INHERITED_ACCESSORS,
        @INHERITED_MERGING_ACCESSORS )
    {
        my $value = $self->$key;
        
        $next_form->$key( $value )
            if defined $value;
    }
    
    my $attrs = $self->attrs;
    
    for my $key ( keys %$attrs ) {
        $next_form->$key( $attrs->{$key} );
    }
    
    $next_form->populate( $page_data );
    $next_form->process;
    
    # encrypt params in hidden field
    $self->_save_hidden_data( $current_page, $next_form, $form );
    
    return $next_form;
}

sub _save_hidden_data {
    my ( $self, $current_page, $next_form, $form ) = @_;
    
    my @valid_names = $form->valid;
    my $hidden_name = $self->multipage_hidden_name;
    
    # don't include the hidden-field's name in valid_names
    @valid_names = grep{ $_ ne $hidden_name } @valid_names;
    
    my %params;
    
    for my $name (@valid_names) {
        my $value = $form->param_value( $name );
        
        $self->set_nested_hash_value( \%params, $name, $value );
    }
    
    my $crypt = Crypt::CBC->new(
        %{ $self->crypt_args }
    );
    
    my $data = {
        current_page => $current_page + 1,
        valid_names  => \@valid_names,
        params       => \%params,
    };
    
    local $Storable::canonicle = 1;
    $data = nfreeze( $data );
    
    $data = $crypt->encrypt_hex( $data );

    my $hidden_field = $next_form->get_field({
        nested_name => $hidden_name,
    });
    
    $hidden_field->default( $data );

    return;
}

1;

__END__

=head1 NAME

HTML::FormFu::MultiPage

=head1 AUTHOR

Carl Franks, C<cfranks@cpan.org>

=head1 LICENSE

This library is free software, you can redistribute it and/or modify it under
the same terms as Perl itself.

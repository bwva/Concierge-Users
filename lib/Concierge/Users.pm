package Concierge::Users v0.7.0;
use v5.40;

use Carp		qw/ croak carp /;
use JSON::PP    qw/ encode_json decode_json /;
use File::Path  qw/ make_path /;

use parent		qw/ Concierge::Users::Meta /;

# ==============================================================================
# Setup Method - One-time configuration
# ==============================================================================

sub setup {
    my ($class, $config) = @_;

    croak "Configuration must be a hash reference"
        unless ref $config eq 'HASH';

    # storage_dir is required - validate/create it FIRST before backend operations
    my $storage_dir = $config->{storage_dir}
    	or croak "Configuration must include 'storage_dir' parameter";
    unless (-d $storage_dir) {
        eval { make_path($storage_dir) };
        croak "Cannot create storage directory: $storage_dir\nError: $@" if $@;
    }

    # Explicit backend selection is required
    my $backend_type = $config->{backend} 
    	or croak "Configuration must include 'backend' parameter 'database', 'file', or 'yaml'";

    # Normalize backend name and determine module name
    my $backend = do {
        my $back = lc $backend_type;
        $back eq 'database' ? 'Database' :
        $back eq 'file'     ? 'File' :
        $back eq 'yaml'     ? 'YAML' :
        croak "Invalid backend type: $backend_type (must be 'database', 'file', or 'yaml')";
    };

    # Load backend module
    my $backend_class = "Concierge::Users::${backend}";
    eval "require $backend_class";
    return {
        success => 0,
        message => "Backend '$backend_type' not available: $@"
    } if $@;

	my $field_meta	= Concierge::Users::Meta::init_field_meta($config);

    # Merge original config with field_meta for backend configure()
    # (backend needs storage_dir and other config options)
    my $backend_config = {
        %$config,
        %$field_meta,
    };

    # Call backend configure() to create storage
    my $configure_result = $backend_class->configure( $backend_config );
    return $configure_result unless $configure_result->{success};

    # Config file is always: storage_dir/users-config.json
    my $config_file = "$storage_dir/users-config.json";

    # Build complete config structure for serialization
    my $config_to_save = {
        version => "$Concierge::Users::VERSION",
        generated => Concierge::Users::Meta->current_timestamp(),
        backend_module => "Concierge::Users::${backend}",
        backend_config => $configure_result->{config},
        fields => $field_meta->{fields},
        field_definitions => $field_meta->{field_definitions},
        storage_initialized => 1,
    };

    # Serialize and save JSON config
    eval {
        open my $fh, '>', $config_file or croak "Cannot open $config_file for writing: $!";
        print {$fh} encode_json($config_to_save);
        close $fh;
    };
    return {
        success => 0,
        message => "Failed to write config file: $config_file\nError: $@"
    } if $@;

    # Generate and save YAML config (human-readable reference)
    my $yaml_file = "$storage_dir/users-config.yaml";
    my $yaml_content = Concierge::Users::Meta::config_to_yaml($config_to_save, $storage_dir);
    eval {
        open my $fh, '>', $yaml_file or croak "Cannot open $yaml_file for writing: $!";
        print {$fh} $yaml_content;
        close $fh;
        chmod 0666, $yaml_file;  # Writable - allows setup() to overwrite
    };
    return {
        success => 0,
        message => "Failed to write YAML config file: $yaml_file\nError: $@"
    } if $@;

    return {
        success => 1,
        message => "Users system configured successfully",
        config_file => $config_file,
        yaml_file => $yaml_file,
    };
}

# ==============================================================================
# Constructor - Load from saved config
# ==============================================================================

sub new {
    my ($class, $config_file) = @_;

    croak "Usage: Concierge::Users->new('/path/to/users-config.json')"
        . "\nCall Concierge::Users->setup() first with configuration to create the config file"
        unless $config_file && -f $config_file;

    # Load and deserialize config
    my $config_json;
    eval {
        open my $fh, '<', $config_file or croak "Cannot open $config_file: $!";
        local $/;  # slurp mode
        $config_json = <$fh>;
        close $fh;
    };
    croak "Failed to read config file: $config_file\nError: $@" if $@;

    my $saved_config;
    eval {
        $saved_config = decode_json($config_json);
    };
    croak "Failed to parse config file: $config_file\nError: $@" if $@;

    # Validate config structure
    croak "Invalid config file: missing 'backend_module' or 'fields'"
        unless $saved_config->{backend_module} && $saved_config->{fields};

    # Load backend module
    my $backend_module = $saved_config->{backend_module};
    eval "require $backend_module";
    croak "Backend '$backend_module' not available: $@" if $@;

    # Instantiate backend with its config (no fields needed for runtime)
    my $backend_obj = $backend_module->new($saved_config->{backend_config});

    # Create Users object - just store what's needed for API operations
    my $self = bless {
        backend            => $backend_obj,
        fields             => $saved_config->{fields},
        field_definitions => $saved_config->{field_definitions},
    }, $class;

    return $self;
}

# ==============================================================================
# Public API Methods
# ==============================================================================

# Register a new user
sub register_user {
    my ($self, $user_data) = @_;

    return { success => 0, message => "User data must be a hash reference" }
        unless ref $user_data eq 'HASH';

    # Clone user_data to avoid modifying caller's hashref
    my $data = { %$user_data };

    # 0. Clean $data
    # Delete any data for system timestamps
    delete $data->{$_} for qw/created_date last_mod_date/;
    # Define undefined values and remove leading and trailing whitespace
    for my $f (keys $data->%*) {
    	$data->{$f} //= '';
    	$data->{$f} =~ s/^\s*|\s*$//g;
    }

    # 1. Validate user_id, including allowing email address as ID
    return { success => 0, message => "user_id is required as 2-30 characters, email OK, no spaces" }
        unless $data->{user_id}
        	&& $data->{user_id} =~ /^[a-zA-Z0-9._@-]{2,30}$/;

    # 2. Validate moniker
    return { success => 0, message => "moniker is required as 2-24 alphanumeric characters, no spaces" }
        unless $data->{moniker}
        && $data->{moniker} =~ /^[a-zA-Z0-9]{2,24}$/;

    # 3. Check if user already exists
    my $existing = $self->get_user($data->{user_id});
    return { success => 0, message => "User '$data->{user_id}' already exists" }
    	if $existing->{success};

    # 4. Store user_id and moniker, then remove from data for further processing
    my $new_user_id = delete $data->{user_id};
    my $user_init_record	= {
    	user_id		=> $new_user_id,
    	moniker		=> delete $data->{moniker},
    };
    for my $field (@{$self->{fields}}) {
    	# Skip user_id and moniker - already set
    	next if $field eq 'user_id' || $field eq 'moniker';

    	# Get field definition
		my $def = $self->{field_definitions}->{$field};
		# Apply default for new records if it is defined
		if (defined $def->{default}) {
			$user_init_record->{$field} = $def->{default};
		}
		# Otherwise apply null_value for record initialization
		elsif (defined $def->{null_value}) {
			$user_init_record->{$field} = $def->{null_value};
		}
		else {
			$user_init_record->{$field} = '';
		}
    }
    my $result = $self->{backend}->add( $new_user_id, $user_init_record );
    return $result unless $result->{success};

    # 5. Validate
    my $validation = $self->validate_user_data( $data );
    return $validation unless $validation->{success};
    # Proceed only with validated data
    my $validated_user_data	= $validation->{valid_data};

    # 6. Populate the record with validated user data
    $result = $self->{backend}->update( $new_user_id, $validated_user_data );

    # Override message to indicate creation rather than update
    $result->{message} = "User '$new_user_id' created";

    # Add warnings to result if any
    $result->{warnings} = $validation->{warnings} if $validation->{warnings};

    return $result;
}

# Get user by ID
sub get_user {
    my ($self, $user_id, $options) = @_;

    return { success => 0, message => "user_id is required" }
        unless $user_id && $user_id =~ /\S/;

    $options ||= {};

    my $fetch_result = $self->{backend}->fetch($user_id);

    unless ($fetch_result->{success}) {
        return { success => 0, message => $fetch_result->{message} };
    }

    my $user_data = $fetch_result->{data};

    # Handle field selection
    if ($options->{fields} && ref $options->{fields} eq 'ARRAY') {
        my %selected;
        $selected{$_} = $user_data->{$_} for @{$options->{fields}};
        $selected{user_id} = $user_data->{user_id};  # Always include user_id
        $user_data = \%selected;
    }

    return {
        success => 1,
        user_id => $user_id,
        user => $user_data
    };
}

# Update user
sub update_user {
    my ($self, $user_id, $updates) = @_;

    return { success => 0, message => "user_id is required" }
        unless $user_id && $user_id =~ /\S/;

    return { success => 0, message => "Updates must be a hash reference" }
        unless ref $updates eq 'HASH';

    # Check if user exists
    my $existing = $self->get_user($user_id);
    unless ($existing->{success}) {
        return { success => 0, message => "User '$user_id' not found" };
    }

    # 0. Clean $updates
    # Delete any data for user_id and system timestamps
    delete $updates->{$_} for qw/user_id created_date last_mod_date/;
    # Define undefined values and remove leading and trailing whitespace
    for my $f (keys $updates->%*) {
    	$updates->{$f} //= '';
    	$updates->{$f} =~ s/^\s*|\s*$//g;
    }

    # 1. Validate 
    my $validation = $self->validate_user_data( $updates );
    return $validation unless $validation->{success};
    # Proceed only with validated data
    my $validated_updates	= $validation->{valid_data};

    # 2. Populate the record with user data
    my $result = $self->{backend}->update( $user_id, $validated_updates );
    
    # Add warnings to result if any
    if ($validation->{warnings}) {
        $result->{warnings} = $validation->{warnings};
    }

    return $result;
}

# List users - only returns user_ids with optional filtering
sub list_users {
    my ($self, $filter_string) = @_;

    # Parse filter string if provided
    my $filters = {};
    if ($filter_string && $filter_string =~ /\S/) {
        $filters = $self->parse_filter_string($filter_string);
    }

    my $users = $self->{backend}->list($filters, {});
    my @user_ids = map { $_->{user_id} } @{$users->{data} || []};

    return {
        success => 1,
        user_ids => \@user_ids,
        total_count => $users->{total_count} || 0,
        filter_applied => ($filter_string && $filter_string =~ /\S/) ? $filter_string : '',
    };
}

# Delete user
sub delete_user {
    my ($self, $user_id) = @_;

    return { success => 0, message => "user_id is required" }
        unless $user_id && $user_id =~ /\S/;

    # Check if user exists
    my $existing = $self->get_user($user_id);
    unless ($existing->{success}) {
        return { success => 0, message => "User '$user_id' not found" };
    }

    # Delete using backend
    my $result = $self->{backend}->delete($user_id);

    return $result;
}

# Utility methods

# Cleanup
sub DESTROY {
    my $self = shift;

    # Disconnect backend if it has a disconnect method
    if ($self->{backend} && $self->{backend}->can('disconnect')) {
        $self->{backend}->disconnect();
    }
}

1;
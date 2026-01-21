package Concierge::Users::Meta v0.7.0;
use v5.40;
use Carp qw/ croak carp /;
use YAML::XS qw/ DumpFile /;

# ABSTRACT: Metadata for fields in Concierge::Users

sub user_core_fields {
	return @Concierge::Users::Meta::core_fields;
}

sub user_standard_fields {
	return @Concierge::Users::Meta::standard_fields;
}

sub user_system_fields {
	return @Concierge::Users::Meta::system_fields;
}

# Get field definition for a specific field
# Returns complete hashref with all field attributes (type, default, validation, etc.)
# Returns undef if field definition not found in this instance's schema
sub get_field_definition {
	my ($self, $field) = @_;

	# Only look in instance field_definitions (set during setup)
	# Do NOT fall back to master list - schema should be enforced
	if ($self->{field_definitions}) {
		return $self->{field_definitions}{$field};
	}

	# No field_definitions available (shouldn't happen in normal use)
	return;
}


# May be directly called as Concierge::Users::Meta::init_field_meta
# or Concierge::Users::Meta->init_field_meta
# Users.pm calls it with its config, which includes any
# field definitions from the calling app, including
# overrides of attributes of the standard field definitions
# Returns the whole backend config, which includes the field definitions
# as well as the ordered field list.
sub init_field_meta {
	my ($self, $config) = @_;
	$config = ref $self eq __PACKAGE__ ? $config : $self;

	# Get field lists from package arrays
	my @core_fields		= @Concierge::Users::Meta::core_fields;
	my @standard_fields	= @Concierge::Users::Meta::standard_fields;
	my @system_fields	= @Concierge::Users::Meta::system_fields;

	# Assemble backend user data fields; always include core fields
	my @fields	= @core_fields;
	# Start with built-in field definitions (clone to avoid modifying master hash)
	my %merged_definitions = map {
		$_ => { $Concierge::Users::Meta::field_definitions{$_}->%* }
	} @core_fields, @system_fields;

	# Add requested standard fields
	my @requested_fields;
	my $req_std_fields	= $config->{include_standard_fields} || 'all';
	if ( ref $req_std_fields eq 'ARRAY' ) {
		@requested_fields	= map { lc $_ } $req_std_fields->@*;
	}
	elsif ( ! ref $req_std_fields ) {
		@requested_fields	= map { lc $_ } split /\s*[,;]\s*/ => $req_std_fields;
	}
	
	my @included_std_fields;
	if ( @requested_fields and $requested_fields[0] =~ /all/i ) {
		@included_std_fields = @standard_fields;
		@requested_fields = ();
	}
	elsif ( @requested_fields ) {
		# make sure requested standard fields are available
		my %standard_fields	= map { $_ => 1 } @standard_fields;
		for my $fld (@requested_fields) {
			if ($standard_fields{$fld}) {
				push @included_std_fields => $fld;
			}
			else {
				carp "Non-standard field requested: $fld; configure with 'app_fields => [ ...]'";
			}
		}
	}
	else {
		# just in case
		@included_std_fields = @standard_fields;
	}
	push @fields, @included_std_fields;
	for my $fld (@included_std_fields) {
		$merged_definitions{$fld} = { $Concierge::Users::Meta::field_definitions{$fld}->%* }
			if $Concierge::Users::Meta::field_definitions{$fld};
	}

	# Process field_overrides - modify built-in field definitions
	# Protected fields (cannot be overridden): user_id, created_date, last_mod_date
	# Protected attributes (cannot be changed): field_name, category
	if ($config->{field_overrides}) {
# 		my @protected_fields = qw/ user_id created_date last_mod_date /;
# 		my %protected_fields = map { $_ => 1 } @protected_fields;
# 		my @protected_attrs = qw/ field_name category /;
# 		my %protected_attrs = map { $_ => 1 } @protected_attrs;

		# *** BVA: This is unnecessary. The module already has
		# %Concierge::Users::Meta::type_validator_map
		# Known validator types for validate_as validation
# 		my %known_validators = map { $_ => 1 } qw/
# 			text enum boolean date timestamp email phone integer moniker name
# 		/;
		# ***
		my @overrides = ref $config->{field_overrides} eq 'ARRAY'
			? $config->{field_overrides}->@*
			: ();

		foreach my $override (@overrides) {
			next unless ref $override eq 'HASH';

			my $field_name = $override->{field_name};
			unless ($field_name) {
				carp "Field override missing field_name; skipping";
				next;
			}

			# Check if field is protected
# 			if ($protected_fields{$field_name}) {
			if ( $field_name =~ /user_id|created_date|last_mod_date/) {
				carp "Cannot override protected field '$field_name'; skipping";
				next;
			}

			# Check if field exists in merged_definitions
			unless ($merged_definitions{$field_name}) {
				carp "Cannot override unknown field '$field_name'; field must be included via include_standard_fields or app_fields";
				next;
			}

			# Process each attribute in the override
			my %warnings;
			foreach my $attr (keys %$override) {
				# Skip field_name itself (it's the identifier, not an attribute to override)
				next if $attr eq 'field_name';

				# Skip protected attributes
# 				if ($protected_attrs{$attr}) {
				if ($attr =~ /field_name|category/) {
					$warnings{$attr} = "protected attribute '$attr' cannot be changed";
					next;
				}

				# Validate validate_as against known types
				if ($attr eq 'validate_as') {
					my $validator_type = $override->{$attr};
# 					unless ($known_validators{$validator_type}) {
					unless ($Concierge::Users::Meta::type_validator_map{$validator_type}) {
						$warnings{$attr} = "unknown validator type '$validator_type' - falling back to 'text'";
						$merged_definitions{$field_name}{$attr} = 'text';
						next;
					}
				}

				# Apply the override
				$merged_definitions{$field_name}{$attr} = $override->{$attr};
			}

			# Auto-update validate_as when type is changed (unless validate_as was also explicitly overridden)
			if (exists $override->{type} && !exists $override->{validate_as}) {
				my $new_type = $override->{type};
# 				if ($known_validators{$new_type}) {
				if ($Concierge::Users::Meta::type_validator_map{$new_type}) {
					$merged_definitions{$field_name}{validate_as} = $new_type;
				}
			}

			# Auto-update must_validate when required is set to 1 (unless must_validate was explicitly overridden)
			if (exists $override->{required} && $override->{required} == 1 && !exists $override->{must_validate}) {
				$merged_definitions{$field_name}{must_validate} = 1;
			}

			# Emit warnings if any
			if (%warnings) {
				my $warning_list = join(', ', map { "$_: $warnings{$_}" } sort keys %warnings);
				carp "Field '$field_name' override: $warning_list";
			}
		}
	}

	# Add app's supplementary fields and merge their definitions
	# But don't allow use of existing field names
	if ($config->{app_fields}) {
		my %reserved_fields	= map { $_ => 1 } 
			@standard_fields, @core_fields, @system_fields;
		my @app_fields;
		if (ref $config->{app_fields} eq 'ARRAY' ) {
			@app_fields = $config->{app_fields}->@*;
		}
		elsif (!ref $config->{app_fields} ) {
			 @app_fields = map { lc $_ } split /\s*[,;]\s*/ =>		
		}
		FIELD: foreach my $field_def (@app_fields) {
			my $field_name;
			my $field_definition;
			if (ref $field_def eq 'HASH') {
				$field_name = $field_def->{field_name};
				if ($reserved_fields{$field_name}) {
					carp "Supplemental field name $field_name already in use";
					next FIELD;
				}
				# Build complete definition for app field
				$field_definition = {
					field_name => $field_name,
					label => delete $field_def->{label} || labelize($field_name),
					category => 'app',
					# Include all provided attributes (type, default, validation, etc.)
					map {
						$_ => $field_def->{$_}
					} grep { !/field_name|label|category/ } keys %$field_def
				};
				unless ( exists $field_definition->{null_value} ) {
					$field_definition->{null_value} = $Concierge::Users::Meta::type_null_values{ $field_def->{type} || 'text' };
				}
			} elsif ( !ref $field_def ) {
				# Simple string field name - create minimal definition
				$field_name = $field_def;
				if ($reserved_fields{$field_name}) {
					carp "Supplemental field name $field_name already in use";
					next FIELD;
				}
				$field_definition = {
					field_name => $field_name,
					label => labelize($field_name),
					category => 'app',
					type => 'text',  # Default type
					validate_as => 'text', # Default validation
					required => 0,
					null_value => '',
				};
			}
			$merged_definitions{$field_name} = $field_definition;
			push @fields, $field_name;
		}
 	}

	# Always add system fields
	push @fields, @system_fields;

	# Auto-set defaults for enum fields that don't have explicit defaults
	# Also create v_options (validated options) without asterisks for internal use
	foreach my $field_name (keys %merged_definitions) {
		my $def = $merged_definitions{$field_name};

		# Process enum options: create v_options without asterisks
		if ($def->{type} eq 'enum' && $def->{options}) {
			# Create clean options list for validation (strip leading asterisk and any following spaces)
			my @clean_options = map { s/^\*\s*//r } $def->{options}->@*;
			$merged_definitions{$field_name}{v_options} = \@clean_options;

			# Auto-set default from * designated option for enum fields
			# Check if default is undefined OR empty string (both should trigger auto-set)
			if (!$def->{default} || $def->{default} eq '') {
				my $default_option	= '';
				for my $opt ($def->{options}->@*) {
					if ($opt =~ /^\*(.+)\s*$/) {
						$default_option = $1; # OK if it's ''
						last;
					}
				}
				$merged_definitions{$field_name}{default} = $default_option;
			}
		}
	}

	my %field_meta	= (
		fields				=> [ @fields ],
		field_definitions	=> { %merged_definitions },
	);

	return \%field_meta;
}

# Type-to-validator mapping for default validation
%Concierge::Users::Meta::type_validator_map = (
	text      => \&validate_text,
	enum      => \&validate_enum,
	boolean   => \&validate_boolean,
	date      => \&validate_date,
	timestamp => \&validate_timestamp,
	email     => \&validate_email,
	phone     => \&validate_phone,
	integer   => \&validate_integer,
	moniker   => \&validate_moniker,
	name      => \&validate_name_field,
);

%Concierge::Users::Meta::type_null_values = (
	text      => '',
	enum      => '',
	boolean   => 0,
	date      => '0000-00-00',
	timestamp => '0000-00-00 00:00:00',
	email     => '',
	phone     => '',
	integer   => 0,
	moniker   => '',
	name      => '',
);

# Get field validator - returns validator based on validate_as or type
sub get_field_validator {
	my ($self, $field) = @_;

	my $field_def = $self->get_field_definition($field);
	return unless $field_def;

	# Check for validate_as specifier (JSON-serializable)
	if ($field_def->{validate_as}) {
		my $validator_type = $field_def->{validate_as};
		return $Concierge::Users::Meta::type_validator_map{$validator_type}
			if $Concierge::Users::Meta::type_validator_map{$validator_type};
	}

	# Return type-derived validator if available
	my $type = $field_def->{type};
	return $Concierge::Users::Meta::type_validator_map{$type}
		if $type && $Concierge::Users::Meta::type_validator_map{$type};

	return;  # No validator available
}

# Get UI-friendly field hints for calling applications
# Returns hashref with: label, type, max_length, options, description, required
sub get_field_hints {
	my ($self, $field) = @_;

	my $field_def = $self->get_field_definition($field);
	return unless $field_def;

	return {
		label => $field_def->{label} || labelize($field_def->{field_name} || $field),
		type => $field_def->{type},
		max_length => $field_def->{max_length},
		options => $field_def->{options},
		description => $field_def->{description},
		required => $field_def->{required},
	};
}

# Get the list of field names for this user object
sub get_user_fields {
	my $self = shift;

	return $self->{fields};
}

# Auto-generate label from field_name
sub labelize {
	my ($field_name)	= @_;
	return unless $field_name;

	# Convert underscore_case to Title Case
	$field_name =~ s/_/ /g;
	$field_name =~ s/\b(\w)/\u$1/g;

	return $field_name;
}

# Generate current date in YYYY-MM-DD format
sub current_date {
	my ($mday, $mon, $year) = gmtime;
	return sprintf("%04d-%02d-%02d", $year + 1900, $mon + 1, $mday);
}

# Generate current timestamp in YYYY-MM-DD HH:MM:SS format
sub current_timestamp {
	my ($sec, $min, $hour, $mday, $mon, $year) = gmtime;
	return sprintf("%04d-%02d-%02d %02d:%02d:%02d",
		$year + 1900, $mon + 1, $mday, $hour, $min, $sec);
}

sub archive_timestamp {
	my ($sec, $min, $hour, $mday, $mon, $year) = localtime;
	return sprintf("%04d%02d%02d_%02d%02d%02d",
		$year + 1900, $mon + 1, $mday, $hour, $min, $sec);
}

# ==============================================================================
# CONFIG DISPLAY METHODS
# ==============================================================================

# Convert config hash to YAML format for storage
# Returns YAML string with warning header
sub config_to_yaml {
	my ($config, $storage_dir) = @_;

	# Build YAML header
	my $yaml = '';
	$yaml .= "#" . ("#" x 78) . "\n";
	$yaml .= "#  WARNING: This is a GENERATED file for reference ONLY\n";
	$yaml .= "#\n";
	$yaml .= "#  Editing this file will NOT affect your Users setup configuration.\n";
	$yaml .= "#\n";
	$yaml .= "#  This file is automatically generated from:\n";
	$yaml .= "#    users-config.json\n";
	$yaml .= "#\n";
	$yaml .= "#  This file:\n";
	$yaml .= "#    $storage_dir/users-config.yaml\n";
	$yaml .= "#" . ("#" x 78) . "\n";
	$yaml .= "\n";

	# Configuration metadata
	$yaml .= "Configuration:\n";
	$yaml .= "  Version: $config->{version}\n";
	$yaml .= "  Backend: $config->{backend_module}\n";
	$yaml .= "  Storage Directory: $storage_dir\n";
	$yaml .= "  Generated: $config->{generated}\n";
	$yaml .= "\n";

	# Field Definitions
	$yaml .= "Field Definitions:\n";

	# Organize fields by category
	my %fields_by_category = (
		'Core Fields' => [grep { my $f=$_; grep { $_ eq $f } @Concierge::Users::Meta::core_fields } @{$config->{fields}}],
		'Standard Fields' => [grep { my $f=$_; grep { $_ eq $f } @Concierge::Users::Meta::standard_fields } @{$config->{fields}}],
		'System Fields' => [grep { my $f=$_; grep { $_ eq $f } @Concierge::Users::Meta::system_fields } @{$config->{fields}}],
		'Application Fields' => [grep { my $f=$_; my $found=0;
			for my $cat (\@Concierge::Users::Meta::core_fields, \@Concierge::Users::Meta::standard_fields, \@Concierge::Users::Meta::system_fields) {
				$found = 1 if grep { $_ eq $f } @$cat;
			}
			!$found;
		} @{$config->{fields}}],
	);

	foreach my $category ('Core Fields', 'Standard Fields', 'System Fields', 'Application Fields') {
		my $fields = $fields_by_category{$category};
		next unless $fields && @$fields;

		$yaml .= "  $category:\n";
		foreach my $field (@$fields) {
			my $def = $config->{field_definitions}{$field};
			next unless $def;

			$yaml .= "    $field:\n";
			$yaml .= "      field_name: $def->{field_name}\n";
			$yaml .= "      type: $def->{type}\n";
			$yaml .= "      required: $def->{required}\n";

			# Only show validate_as if it's different from type
			if ($def->{validate_as} && $def->{validate_as} ne $def->{type}) {
				$yaml .= "      validate_as: $def->{validate_as}\n";
			}

			$yaml .= "      default: " . _yaml_scalar_value($def->{default}) . "\n";

			# Show options if present
			if ($def->{options} && @{$def->{options}}) {
				$yaml .= "      options:  (asterisk '*' designates default option)\n";
				foreach my $opt (@{$def->{options}}) {
					$yaml .= "        - $opt\n";
				}
			}

			# Show description if present
			if ($def->{description}) {
				$yaml .= "      description: \"$def->{description}\"\n";
			}

			# Show other key attributes if present
			$yaml .= "      max_length: $def->{max_length}\n" if $def->{max_length};
			$yaml .= "      must_validate: $def->{must_validate}\n" if $def->{must_validate};
			$yaml .= "      null_value: " . _yaml_scalar_value($def->{null_value}) . "\n";

			$yaml .= "\n";
		}
	}

	return $yaml;
}

# Helper to properly quote YAML scalar values
sub _yaml_scalar_value {
	my ($value) = @_;

	# Handle undefined values
	return 'null' unless defined $value;

	# Handle empty strings
	return '""' if $value eq '';

	# Handle numeric values
	return $value if $value =~ /^\-?\d+$/;

	# Handle boolean
	return $value if $value =~ /^[01]$/;

	# Quote strings with spaces or special chars
	return $value if $value =~ /^\S+$/;
	return "\"$value\"";
}

# Show default configuration (from __DATA__ section)
# Can be called as class method or instance method
# Parameters (optional hash):
#   output_path => '/path/to/file.yaml'  # Save to file instead of STDOUT
sub show_default_config {
	my ($self, %params) = @_;

	# Read from __DATA__ section
    my @data        = <DATA>;
	say @data;
}

# Show configuration for an existing setup
# Must be called as instance method on a Users object
# Parameters (optional hash):
#   output_path => '/path/to/file.yaml'  # Save to different location
sub show_config {
	my ($self, %params) = @_;

	# Check if this is a valid Users object with storage_dir
	unless (ref $self && $self->{backend}) {
		return {
			success => 0,
			message => "show_config() must be called on a Users instance. "
				. "Use show_default_config() to view default configuration."
		};
	}

	# Get storage_dir from backend config
	my $storage_dir = $self->{backend}{storage_dir}
		or return {
			success => 0,
			message => "Cannot determine storage directory from Users object"
		};

	my $yaml_file = $params{output_path} || "$storage_dir/users-config.yaml";

	# Check if YAML config file exists
	unless (-f $yaml_file) {
		return {
			success => 0,
			message => "Configuration file not found: $yaml_file\n"
				. "Note: YAML config files are created automatically during setup().\n"
				. "If you just created this setup, the file should exist. "
				. "Otherwise, the setup may be incomplete."
		};
	}

	# Read and display the YAML file
	my $yaml_content;
	eval {
		open my $fh, '<', $yaml_file or croak "Cannot open $yaml_file: $!";
		local $/;
		$yaml_content = <$fh>;
		close $fh;
	};
	if ($@) {
		return {
			success => 0,
			message => "Failed to read configuration file: $@"
		};
	}

	# Print to STDOUT
	print $yaml_content;

	return {
		success => 1,
		message => "Configuration displayed from $yaml_file",
		config_file => $yaml_file
	};
}


# ==============================================================================
# VALIDATOR METHODS
# All validators receive: ($user_data, $field_name, $field_def)
# Validators modify $user_data->{$field_name} directly if substitution needed
# All validators return: { success => 1|0, message => "..." }
# ==============================================================================

# Validate enum fields against options
sub validate_enum {
	my ($user_data, $field_name, $field_def) = @_;

	my $value = $user_data->{$field_name};

	# Use v_options (validated options without asterisks)
	my $options = $field_def->{v_options} || [];

	# Check if value is in the allowed options
	if (grep { $_ eq $value } @$options) {
		return { success => 1 };
	}

	return {
		success => 0,
		message => "$field_def->{label} must be one of: " . join(', ', @$options),
	};
}

# Validate text fields with length checking
sub validate_text {
	my ($user_data, $field_name, $field_def) = @_;

	my $value = $user_data->{$field_name};

	# Check max_length
	if ($field_def->{max_length} && length($value) > $field_def->{max_length}) {
		return {
			success => 0,
			message => "$field_def->{label} must not exceed maximum length of $field_def->{max_length} characters"
		};
	}

	return { success => 1 };
}

# Validate email format
sub validate_email {
	my ($user_data, $field_name, $field_def) = @_;

	my $value = $user_data->{$field_name};

	# Check email format
	if ($value =~ /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/) {
		return { success => 1 };
	}

	return { success => 0, message => "$field_def->{label} must be a valid email address" };
}

# Validate date format
sub validate_date {
	my ($user_data, $field_name, $field_def) = @_;

	my $value = $user_data->{$field_name};

	# Check YYYY-MM-DD format
	if ($value =~ /^\d{4}-\d{2}-\d{2}$/) {
		return { success => 1 };
	}

	return {
		success => 0,
		message => "Invalid date format for $field_def->{label}",
	};
}

# Validate timestamp format
sub validate_timestamp {
	my ($user_data, $field_name, $field_def) = @_;

	my $value = $user_data->{$field_name};

	# Check YYYY-MM-DD HH:MM:SS format
	if ($value =~ /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}$/) {
		return { success => 1 };
	}

	return {
		success => 0,
		message => "Invalid timestamp format for $field_def->{label}, using null value"
	};
}

# Validate boolean (1|0) #  or resolves Perl true/false?
sub validate_boolean {
	my ($user_data, $field_name, $field_def) = @_;

	my $value = $user_data->{$field_name};

	# Check if value is explicitly 0 or 1
	if (defined $value && $value =~ /^[01]$/) {
		return { success => 1 };
	}
	# *** BVA: OR:
# 	my $null_value = $field_def->{null_value} // 0;
# 	if (!!$value && $value ne $null_value) {
# 		return { success => 1 };
# 	}
	# ***
	# Invalid boolean 
	return {
		success => 0,
		message => "Invalid value '$value' for boolean $field_def->{label}"
	};
}

# Validate phone format
sub validate_phone {
	my ($user_data, $field_name, $field_def) = @_;

	my $value = $user_data->{$field_name};

	# Check phone format
	if ($value =~ /^\+?[\d\s\-\(\)]+$/ && length($value) >= 7) {
		return { success => 1 };
	}

	# Invalid phone
	return { success => 0, message => "$field_def->{label} must be a valid 10-character phone number" };
}

# Validate integer
sub validate_integer {
	my ($user_data, $field_name, $field_def) = @_;

	my $value = $user_data->{$field_name};

	# Check integer format (allow negative numbers)
	if ($value =~ /^\-?\d+$/) {
		return { success => 1 };
	}

	return { success => 0, message => "$field_def->{label} must be a whole number" };
}

sub validate_moniker {
    my ($user_data, $field_name, $field_def) = @_;

    my $value = $user_data->{$field_name};

    return { success => 0, message => "moniker is required as 2-24 alphanumeric characters, no spaces" }
        unless $value && $value =~ /^[a-zA-Z0-9]{2,24}$/;

    return { success => 1 };
}

sub validate_name_field {
    my ($user_data, $field_name, $field_def) = @_;

    my $value = $user_data->{$field_name};

    # Allow letters, hyphens, apostrophes, and internal spaces
    return { success => 0, message => "$field_def->{label} contains invalid characters" }
    	unless $value 
    		&& $value =~ /^[a-zA-Z\u00C0-\u024F'’\-.]+(?:\s+[a-zA-Z\u00C0-\u024F'’\-.]+)*$/;
    
    return { success => 1 };
}

@Concierge::Users::Meta::core_fields	= ( qw/
	user_id
	moniker
	user_status
	access_level
/ );

@Concierge::Users::Meta::standard_fields	= ( qw/
	first_name
	middle_name
	last_name
	prefix
	suffix
	organization
	title
	email
	phone
	text_ok
	last_login_date
	term_ends
/ );

@Concierge::Users::Meta::system_fields	= ( qw/
        last_mod_date
        created_date
/ );

%Concierge::Users::Meta::field_definitions	= (
	# Core field definitions
	user_id => {
		field_name => 'user_id',
		label => 'User ID',
		description => 'User login ID - Primary authentication identifier',
		type => 'system',
		required => 1,
		options => [],
		default => '',
		null_value => '',
		max_length => 30,
		must_validate => 0,
	},
	moniker => {
		field_name => 'moniker',
		label => 'Moniker',
		description => 'User\'s preferred display name, nickname, or initials',
		type => 'text',
		required => 1,
		options => [],
		default => '',
		null_value => '',
		max_length => 24,
		validate_as => 'moniker',
		must_validate => 1,
	},
	user_status => {
		field_name => 'user_status',
		label => 'User Status',
		description => 'Account status for access control',
		type => 'enum',
		required => 1,
		options => ['*Eligible', 'OK', 'Inactive'],
		default => '',  # Will be auto-set to option with '*'
		null_value => '',
		max_length => 20,
		validate_as => 'enum',
		must_validate => 1,
	},
	access_level => {
		field_name => 'access_level',
		label => 'Access Level',
		description => 'Permission level for feature access',
		type => 'enum',
		required => 1,
		options => ['*anon', 'visitor', 'member', 'staff', 'admin'],
		default => '',  # Will be auto-set to option with '*'
		null_value => '',
		max_length => 20,
		validate_as => 'enum',
		must_validate => 1,
	},

	# Standard field definitions
	first_name => {
		field_name => 'first_name',
		label => 'First Name',
		description => 'User\'s first name',
		type => 'text',
		required => 0,
		options => [],
		default => '',
		null_value => '',
		max_length => 50,
		validate_as => 'name',
		must_validate => 1,
	},
	middle_name => {
		field_name => 'middle_name',
		label => 'Middle Name',
		description => 'User\'s middle name',
		type => 'text',
		required => 0,
		options => [],
		default => '',
		null_value => '',
		max_length => 50,
		validate_as => 'name',
		must_validate => 1,
	},
	last_name => {
		field_name => 'last_name',
		label => 'Last Name',
		description => 'User\'s last name',
		type => 'text',
		required => 0,
		options => [],
		default => '',
		null_value => '',
		max_length => 50,
		validate_as => 'name',
		must_validate => 1,
	},
	prefix => {
		field_name => 'prefix',
		label => 'Prefix',
		description => 'Name prefix or title',
		type => 'enum',
		required => 0,
		options => ['*', 'Dr', 'Mr', 'Ms', 'Mrs', 'Mx', 'Prof', 'Hon', 'Sir', 'Madam'],
		default => '',
		null_value => '',  # Will be auto-set to option with '*'
		max_length => 10,
		validate_as => 'enum',
		must_validate => 0,
	},
	suffix => {
		field_name => 'suffix',
		label => 'Suffix',
		description => 'Name suffix or professional designation',
		type => 'enum',
		required => 0,
		options => ['*', 'Jr', 'Sr', 'II', 'III', 'IV', 'V', 'PhD', 'MD', 'DDS', 'Esq'],
		default => '',  # Will be auto-set to option with '*'
		null_value => '',
		max_length => 10,
		validate_as => 'enum',
		must_validate => 0,
	},
	organization => {
		field_name => 'organization',
		label => 'Organization',
		description => 'User\'s organization or affiliation',
		type => 'text',
		required => 0,
		options => [],
		default => '',
		null_value => '',
		max_length => 100,
		validate_as => 'text',
		must_validate => 0,
	},
	title => {
		field_name => 'title',
		label => 'Title',
		description => 'User\'s position or job title',
		type => 'text',
		required => 0,
		options => [],
		default => '',
		null_value => '',
		max_length => 100,
		validate_as => 'text',
		must_validate => 0,
	},
	email => {
		field_name => 'email',
		label => 'Email',
		description => 'Email address for notifications',
		type => 'email',
		required => 0,
		options => [],
		default => '',
		null_value => '',
		max_length => 255,
		validate_as => 'email',
		must_validate => 0,
	},
	phone => {
		field_name => 'phone',
		label => 'Phone',
		description => 'Phone number with country code',
		type => 'phone',
		required => 0,
		options => [],
		default => '',
		null_value => '',
		max_length => 20,
		validate_as => 'phone',
		must_validate => 0,
	},
	text_ok => {
		field_name => 'text_ok',
		label => 'Text OK',
		description => 'Consent for text messages (1=yes, 0=no)',
		type => 'boolean',
		required => 0,
		options => [],
		default => '',
		null_value => 0,
		max_length => 1,
		validate_as => 'boolean',
		must_validate => 0,
	},
	term_ends => {
		field_name => 'term_ends',
		label => 'Term Ends',
		description => 'Account expiration date (YYYY-MM-DD)',
		type => 'date',
		required => 0,
		options => [],
		default => '',
		null_value => '0000-00-00',
		max_length => 10,
		validate_as => 'date',
		must_validate => 0,
	},
	last_login_date => {
		field_name => 'last_login_date',
		label => 'Last Login Date',
		description => 'Timestamp of last successful login',
		type => 'timestamp',
		required => 0,
		options => [],
		default => '0000-00-00 00:00:00',
		null_value => '0000-00-00 00:00:00',
		max_length => 19,
		validate_as => 'timestamp',
		must_validate => 0,
	},

	# System field definitions
	last_mod_date => {
		field_name => 'last_mod_date',
		label => 'Last Modification Date',
		description => 'Timestamp of last profile modification',
		type => 'system',
		required => 0,
		options => [],
		default => '0000-00-00 00:00:00',
		null_value => '0000-00-00 00:00:00',
		max_length => 19,
		must_validate => 0,
	},
	created_date => {
		field_name => 'created_date',
		label => 'Created Date',
		description => 'Timestamp when user account was created',
		type => 'system',
		required => 1,
		options => [],
		default => '0000-00-00 00:00:00',
		null_value => '0000-00-00 00:00:00',
		max_length => 19,
		must_validate => 0,
	},
);

sub validate_user_data {
    my ($self, $user_data) = @_;

    return { success => 1, valid_data => $user_data, message => 'Validation skipped per environment variable USERS_SKIP_VALIDATION' }
	if $ENV{USERS_SKIP_VALIDATION};

    my @warnings;
	my $validated_data	= {};
    foreach my ($field, $value) ( $user_data->%* ) {
        # Get field definition
        my $field_def	= $self->get_field_definition($field);

        # Skip unknown fields with warning
        unless (defined $field_def) {
            push @warnings, "Field '$field' not recognized in schema; input data skipped";
            next;
        }

		# Fail if a required field isn't provided a value
		# or the value is the same as the field's null_value
		if ( !defined $value or $value eq $field_def->{null_value} ) {
			return { success => 0, message => "$field_def->{label} is required" }
				if $field_def->{required}; # Stops input
			next;	# OK if value is null_value and not required,
					# but no need to validate or input
		}

        # Get validator for this field
        my $validator = $self->get_field_validator($field);
        unless ($validator) { # No validator available, skip
        	push @warnings => "Validator not found for '$field'; input skipped";
        	next;
        }

        # Run validator
        my $result = $validator->($user_data, $field, $field_def);

        # Collect warnings
        if ($result->{message}) {
            push @warnings, "$field: $result->{message}";
        }

		# Only validated data will be returned
        if ($result->{success}) {
        	$validated_data->{$field} = $value;
        }
        # Fail on validation errors only if must_validate is set for a field
		elsif ($field_def->{must_validate}) {
			return { success => 0, message => $result->{message}, field => $field };
		}
    }

    # Return success with validated data and any warnings
    my $outcome				= { success => 1, valid_data => $validated_data };
    $outcome->{warnings}	= \@warnings if @warnings;
    return $outcome;
}

# Parse filter DSL string into filter structure
sub parse_filter_string {
    my ($self, $filter_string) = @_;

    my @or_groups = split /\s*\|\s*/, $filter_string;
    my @parsed_filters;

    foreach my $group (@or_groups) {
        my @and_conditions = split /\s*;\s*/, $group;
        my @parsed_and;

        foreach my $condition (@and_conditions) {
            # Parse [field][op][value]
            if ($condition =~ /^(\w+)(=|:|!|>|<)(.+)$/) {
                my ($field, $op, $value) = ($1, $2, $3);

                # Validate field exists
                unless (grep { $_ eq $field } @{$self->{fields}}) {
                    carp "Warning: Unknown field '$field' in filter";
                    next;
                }

                push @parsed_and, {
                    field => $field,
                    op => $op,
                    value => $value
                };
            } else {
                carp "Warning: Invalid filter condition '$condition'";
            }
        }

        # Only add non-empty AND groups
        if (@parsed_and) {
            push @parsed_filters, \@parsed_and;
        }
    }

    # Return empty hash if no valid filters
    return {} unless @parsed_filters;

    # Return structure for backend processing
    return {
        or_groups => \@parsed_filters,
        raw => $filter_string
    };
}

1;

__DATA__
################################################################################
#  Concierge::Users DEFAULT Configuration Template                            #
#                                                                              #
#  This shows the built-in field definitions and default configuration.       #
#  Editing this file will NOT create or modify a Users setup.                #
#                                                                              #
#  To create a new setup, use the Concierge::Users API:                       #
#    my $users = Concierge::Users->new();                                    #
#    $users->setup(...);                                                     #
#                                                                              #
#  To view an existing setup's configuration:                                 #
#    $users->show_config();                                                  #
################################################################################

Configuration:
  Version: v0.7.0
  Backend: Concierge::Users::Database  # Default; can be 'database', 'file', or 'yaml'
  Storage Directory: /path/to/storage  # Set during setup
  Generated: 2026-01-06 19:10:18

Field Definitions:
  Core Fields:
    user_id:
      field_name: user_id
      type: system
      required: 1
      default: ""
      description: "User login ID - Primary authentication identifier"
      max_length: 30
      null_value: ""

    moniker:
      field_name: moniker
      type: text
      required: 1
      validate_as: moniker
      default: ""
      description: "User's preferred display name, nickname, or initials"
      max_length: 24
      must_validate: 1
      null_value: ""

    user_status:
      field_name: user_status
      type: enum
      required: 1
      default: Eligible
      options:
        - *Eligible
        - OK
        - Inactive
      description: "Account status for access control"
      max_length: 20
      must_validate: 1
      null_value: ""

    access_level:
      field_name: access_level
      type: enum
      required: 1
      default: anon
      options:  (asterisk '*' designates default option)
        - *anon
        - visitor
        - member
        - staff
        - admin
      description: "Permission level for feature access"
      max_length: 20
	  validate_as: enum
      must_validate: 1
      null_value: ""

  Standard Fields:
    first_name:
      field_name: first_name
      type: text
      required: 0
      validate_as: name
      default: ""
      description: "User's first name"
      max_length: 50
      must_validate: 1
      null_value: ""

    middle_name:
      field_name: middle_name
      type: text
      required: 0
      validate_as: name
      default: ""
      description: "User's middle name"
      max_length: 50
      must_validate: 1
      null_value: ""

    last_name:
      field_name: last_name
      type: text
      required: 0
      validate_as: name
      default: ""
      description: "User's last name"
      max_length: 50
      must_validate: 1
      null_value: ""

    prefix:
      field_name: prefix
      type: enum
      required: 0
      default: ""
      options:  (asterisk '*' designates default option)
        - *
        - Dr
        - Mr
        - Ms
        - Mrs
        - Mx
        - Prof
        - Hon
        - Sir
        - Madam
      description: "Name prefix or title"
      max_length: 10
	  validate_as: enum
      null_value: ""

    suffix:
      field_name: suffix
      type: enum
      required: 0
      default: ""
      options:  (asterisk '*' designates default option)
        - *
        - Jr
        - Sr
        - II
        - III
        - IV
        - V
        - PhD
        - MD
        - DDS
        - Esq
      description: "Name suffix or professional designation"
      max_length: 10
	  validate_as: enum
      null_value: ""

    organization:
      field_name: organization
      type: text
      required: 0
      default: ""
      description: "User's organization or affiliation"
      max_length: 100
	  validate_as: text
      null_value: ""

    title:
      field_name: title
      type: text
      required: 0
      default: ""
      description: "User's position or job title"
      max_length: 100
	  validate_as: text
      null_value: ""

    email:
      field_name: email
      type: email
      required: 0
      default: ""
      description: "Email address for notifications"
      max_length: 255
	  validate_as: email
      null_value: ""

    phone:
      field_name: phone
      type: phone
      required: 0
      default: ""
      description: "Phone number with country code"
      max_length: 20
	  validate_as: phone
      null_value: ""

    text_ok:
      field_name: text_ok
      type: boolean
      required: 0
      default: ""
      description: "Consent for text messages (1=yes, 0=no)"
      max_length: 1
	  validate_as: boolean
      null_value: 0

    last_login_date:
      field_name: last_login_date
      type: timestamp
      required: 0
      default: "0000-00-00 00:00:00"
      description: "Timestamp of last successful login"
      max_length: 19
	  validate_as: timestamp
      null_value: "0000-00-00 00:00:00"

    term_ends:
      field_name: term_ends
      type: date
      required: 0
      default: ""
      description: "Account expiration date (YYYY-MM-DD)"
      max_length: 10
	  validate_as: date
      null_value: 0000-00-00

  System Fields:
    last_mod_date:
      field_name: last_mod_date
      type: system
      required: 0
      default: "0000-00-00 00:00:00"
      description: "Timestamp of last profile modification"
      max_length: 19
	  validate_as: timestamp
      null_value: "0000-00-00 00:00:00"

    created_date:
      field_name: created_date
      type: system
      required: 1
      default: "0000-00-00 00:00:00"
      description: "Timestamp when user account was created"
      max_length: 19
	  validate_as: timestamp
      null_value: "0000-00-00 00:00:00"

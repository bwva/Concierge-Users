# Concierge::Users

A dedicated user data management system providing clean separation between application logic and data persistence. Supports multiple storage backends (SQLite Database, CSV/TSV files, YAML files) with comprehensive field validation, CRUD operations, and filtering.

## VERSION

v0.7.0

## DESCRIPTION

Concierge::Users is a production-ready user data management module designed for Perl applications. It provides a clean API for managing user records with support for file-based storage backends that are easy to deploy and maintain.

## FEATURES

- **File-Based Storage Backends**
  - SQLite Database (via DBI)
  - CSV/TSV file storage
  - YAML file storage
  - Simple deployment - no database server required

- **Field Management**
  - Core fields: user_id, moniker, user_status, access_level
  - Standard fields: first_name, last_name, email, phone, etc.
  - Custom application fields
  - Field-level validation (email, phone, date, timestamp, boolean, enum, etc.)
  - Protected system fields (created_date, last_mod_date)

- **Data Operations**
  - Create, read, update, delete (CRUD) users
  - Filter by any field
  - Field overrides (change labels, defaults, validation types)

- **Data Integrity**
  - Comprehensive field validation
  - Null value handling per field type
  - Required field enforcement
  - Automatic archiving on re-setup
  - Service layer pattern (structured hashref returns)

## INSTALLATION

From CPAN:
```bash
cpanm Concierge::Users
```

From source:
```bash
perl Makefile.PL
make
make test
make install
```

## QUICK START

```perl
use Concierge::Users;

# Setup with SQLite database backend
Concierge::Users->setup(
    storage_dir  => '/var/lib/myapp/users',
    backend      => 'Database',
    include_standard_fields => 'all',
);

# Setup with CSV file backend
Concierge::Users->setup(
    storage_dir  => '/var/lib/myapp/users',
    backend      => 'File',
    backend_config => {
        file_format => 'csv',
    },
    include_standard_fields => [qw/email phone/],
);

# Setup with YAML file backend
Concierge::Users->setup(
    storage_dir  => '/var/lib/myapp/users',
    backend      => 'YAML',
    include_standard_fields => 'all',
);

# Create a Users instance
my $users = Concierge::Users->new('/var/lib/myapp/users/users-config.json');

# Register a new user
my $result = $users->register_user({
    user_id     => 'jsmith',
    moniker     => 'John',
    user_status => 'Eligible',
    access_level => 'member',
    email       => 'john@example.com',
    phone       => '555-1234',
});

# Retrieve a user
$result = $users->get_user('jsmith');

# Update a user
$result = $users->update_user('jsmith', { phone => '555-5678' });

# List users with filtering
$result = $users->list_users('user_status=Active');

# Delete a user
$result = $users->delete_user('jsmith');
```

## ADVANCED CONFIGURATION

### Custom Application Fields

```perl
Concierge::Users->setup(
    storage_dir  => '/var/lib/myapp/users',
    backend      => 'Database',
    include_standard_fields => 'all',
    app_fields => [
        {
            field_name => 'bio',
            type       => 'text',
            max_length => 500,
            label      => 'Biography',
        },
        {
            field_name => 'subscription_level',
            type       => 'enum',
            options    => ['*Free', 'Premium', 'Enterprise'],
            required   => 1,
        },
        {
            field_name => 'terms_accepted',
            type       => 'boolean',
            label      => 'Accept Terms of Service',
        },
    ],
);
```

### Field Overrides

```perl
Concierge::Users->setup(
    storage_dir  => '/var/lib/myapp/users',
    backend      => 'Database',
    include_standard_fields => 'all',
    field_overrides => [
        {
            field_name => 'user_status',
            options    => ['*Active', 'Inactive', 'Suspended'],
        },
        {
            field_name => 'email',
            required   => 1,
        },
        {
            field_name => 'phone',
            label      => 'Contact Number',
        },
    ],
);
```

### Custom Validation with validate_as

```perl
Concierge::Users->setup(
    storage_dir  => '/var/lib/myapp/users',
    backend      => 'File',
    include_standard_fields => 'all',
    app_fields => [
        {
            field_name  => 'username',
            type        => 'text',
            validate_as => 'moniker',  # Use moniker validator (alphanumeric, 2-24 chars)
            required    => 1,
        },
        {
            field_name  => 'display_name',
            type        => 'text',
            validate_as => 'name',     # Use name validator (letters, spaces, hyphens)
            max_length  => 50,
        },
    ],
);
```

## DEVELOPMENT

### Repository Structure

```
Concierge-Users/
├── lib/Concierge/           # Source modules
├── t/                   # Test suite
├── examples/            # Example applications
│   ├── db-app/         # Database backend example
│   ├── file-app/       # CSV/TSV file backend example
│   └── yaml-app/       # YAML file backend example
├── Makefile.PL         # CPAN installation script
└── README.md           # This file
```

### Development Workflow

1. **Edit** files in the Git repository
2. **Test** using blib (doesn't affect installed version):
   ```bash
   perl Makefile.PL
   make
   prove -blib t/*.t
   ```
3. **Commit** changes to Git
4. **Install** when ready for production:
   ```bash
   make install
   ```

This workflow lets you:
- Develop and test without breaking your production Perl environment
- Keep stable versions installed while working on new features
- Install to site_perl only when changes are tested and ready

### Running Tests

```bash
# From repository directory
perl Makefile.PL
make
prove -blib t/*.t

# Or with verbose output
prove -vblib t/*.t
```

## BACKEND CONFIGURATION

### Database Backend (SQLite)

```perl
Concierge::Users->setup(
    storage_dir  => '/var/lib/users',
    backend      => 'Database',
);
```

Creates `/var/lib/users/users.db` SQLite database.

### File Backend (CSV/TSV)

```perl
Concierge::Users->setup(
    storage_dir  => '/var/lib/users',
    backend      => 'File',
    backend_config => {
        file_format => 'csv',  # or 'tsv'
    },
);
```

Creates `/var/lib/users/users.csv` (or `.tsv`) file.

### YAML Backend

```perl
Concierge::Users->setup(
    storage_dir  => '/var/lib/users',
    backend      => 'YAML',
);
```

Creates YAML files in `/var/lib/users/data/` (one file per user).

## FIELD VALIDATION

Concierge::Users provides built-in validators for common field types:

- **text** - General text with optional max_length
- **email** - Email address format validation
- **phone** - Phone number format (flexible)
- **date** - YYYY-MM-DD format
- **timestamp** - YYYY-MM-DD HH:MM:SS or YYYY-MM-DDTHH:MM:SS format
- **boolean** - Strict 1 or 0
- **integer** - Whole numbers (positive or negative)
- **enum** - Must match one of defined options
- **moniker** - Alphanumeric usernames (2-24 chars)
- **name** - Names with letters, spaces, hyphens, apostrophes

## DATA ARCHIVING

When you call `setup()` with a different configuration (e.g., new fields or field overrides), existing data is automatically archived:

- **Database**: Table renamed to `users_YYYYMMDD_HHMMSS`
- **File**: File renamed to `users_YYYYMMDD_HHMMSS.csv/tsv`
- **YAML**: Directory `users_YYYYMMDD_HHMMSS/` created with all `.yaml` files

This prevents accidental data loss during schema changes. The archived data is preserved but not actively used.

## PERFORMANCE AND SCALABILITY

Concierge::Users has been tested with datasets ranging from small deployments (2-50 users) to larger deployments (up to 1000+ users). Performance characteristics vary by backend:

### Database Backend (SQLite) - Best for Larger Datasets

- **Create**: ~4,200 users/second (sustained performance)
- **Read**: Virtually instant (< 0.003 seconds to list 1,000 users)
- **Update**: ~4,700 users/second
- **Delete**: ~4,800 users/second
- **Filter**: Excellent performance, scales linearly

**Recommended for**: 500+ users or when high-performance CRUD operations are needed.

**Scaling Projections** (based on observed linear performance):
- 1,000 users: < 0.3 seconds to create, instant reads
- 5,000 users: ~1.2 seconds to create, still instant reads
- 10,000 users: ~2.5 seconds to create, reads remain sub-second

### File Backend (CSV/TSV) - Good for Read-Heavy Workloads

- **Create**: ~1,000 users/second for 100 users, scales to ~115 users/second for 1,000 users
- **Read**: Fast (< 0.007 seconds to list 1,000 users)
- **Update**: Moderate performance, best for occasional updates
- **Best for**: Read-heavy applications with moderate write requirements

### YAML Backend - Excellent for Individual Operations

- **Create**: ~980 users/second (consistent performance)
- **Read**: Good for individual user access (0.44 seconds to list 1,000)
- **Update**: ~850 users/second
- **Best for**: Applications that primarily access users individually
- **Note**: File-system dependent; each user stored as separate `.yaml` file

### Backend Selection Guidance

- **< 100 users**: Any backend performs well
- **100-500 users**: All backends suitable; choose based on deployment preferences
- **500+ users**: Database backend recommended for optimal performance
- **5,000+ users**: Database backend strongly recommended

### Installation Notes for Database Backend

SQLite is the database backend used by the Database option. It is typically available in most Perl installations via `DBD::SQLite`. If not available:

```bash
# Install DBD::SQLite if needed
cpanm DBD::SQLite
```

SQLite requires no external database server configuration, making it ideal for embedded applications and simple deployments.

### Bulk Operations

Performance testing indicates that bulk user creation (e.g., initial data import or migrations) is an infrequent operation. Even for file-based backends, one-time bulk creation of 1,000 users completes in under 10 seconds, which is acceptable for initialization scenarios.

## REQUIREMENTS

- Perl 5.40 or higher
- DBI (for Database backend)
- DBD::SQLite (for Database backend)
- YAML::Tiny (for YAML backend)
- JSON::PP
- File::Path
- Test2::V0 (for testing)

## AUTHOR

Your Name <your.email@example.com>

## LICENSE

This module is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

## SEE ALSO

- Concierge::Users::Meta - Field definitions and validation
- Concierge::Users::Database - SQLite database backend
- Concierge::Users::File - File backend (CSV/TSV)
- Concierge::Users::YAML - YAML file backend

## CHANGES

See Changes file for revision history.

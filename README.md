# Media Categorizer

A Python utility for programmatically assigning custom taxonomy terms to WordPress media library items (attachments), based on filename keyword matches.

This tool is designed for use in local or staging environments where automated taxonomy tagging can save time and enforce consistency.

---

## 🚀 Quick Start

### Automated Setup (Recommended)
```bash
# Clone or download the project
git clone https://github.com/plymouthvan/WP-Media-Categorizer.git
cd WP-Media-Categorizer

# Run the setup script
./install-deps.sh

# Follow the prompts to set up dependencies
# Then activate virtual environment if you chose to create one:
source venv/bin/activate

# Test the workflow
python preprocess_media.py --limit=5 --verbose
python apply_terms_direct.py --dry-run --verbose
```

### Manual Setup
If you prefer to install dependencies manually:

```bash
# Install Python dependencies
pip install pyyaml pymysql

# Or with virtual environment
python3 -m venv venv
source venv/bin/activate
pip install pyyaml pymysql
```

## 🔧 Requirements

- **Python 3.8+** with PyYAML and pymysql packages
- WordPress CLI (`wp`) must be installed and available in your shell
- The WordPress installation must be accessible and functioning
- A custom taxonomy named `media_category` must already be registered
- MySQL database access credentials for your WordPress installation

**Note:** Use `./install-deps.sh` for automated dependency setup with virtual environment support.

---

## 📁 Project Structure

```
media-categorizer/
├── preprocess_media.py      # Phase 1: Fetch attachments and find matches
├── apply_terms_direct.py    # Phase 2: Apply taxonomy terms via direct DB access
├── install-deps.sh          # Dependency setup script
├── config.yml               # Keyword mapping, DB credentials & settings
└── README.md                # This file
```

---

## 🧠 How it Works

The tool uses a **two-phase Python-only architecture**:

### Phase 1: Preprocessing (`preprocess_media.py`)
1. Connects to WordPress via wp-cli to fetch all media attachments
2. Processes filename keyword matches based on your `config.yml` mappings
3. Outputs results to `tmp/matches.json` in a standardized format

### Phase 2: Application (`apply_terms_direct.py`)
1. Reads the matches from `tmp/matches.json`
2. Connects directly to the MySQL database using your credentials
3. Creates missing taxonomy terms with proper hierarchical structure
4. Assigns terms to attachments via direct database writes
5. Updates term counts and flushes WordPress cache
6. Generates detailed CSV logs of all operations

**Default behavior:** Runs in dry-run mode to show what would happen before making changes.

---

## 📝 config.yml Format

```yaml
settings:
  wp_path: /path/to/wordpress
  db_host: localhost
  db_user: wp_user
  db_pass: wp_pass
  db_name: wp_database
  apply_taxonomy:
    mode: all  # Options: all, children_only, bottom_only
  backup:
    enabled: true
    output_path: ./backups/media-categorizer-$(date +%F_%H-%M-%S).sql
  output_csv_path: ./logs/media-categorizer-log-$(date +%F_%H-%M-%S).csv

mappings:
  Formals:
    match: "Formals"
    terms:
      - Wedding > Portraits
  Candids:
    match: "Candids"
    terms:
      - Wedding > Preparations
  Ceremony:
    match: "Ceremony"
    terms:
      - Wedding > Ceremony
  PatternExample:
    match: "(?i)^wedding.*details"
    regex: true
    terms:
      - Wedding > Details
```

### Database Configuration
You must provide MySQL credentials for your WordPress database:
- `db_host`: Database server hostname (usually `localhost`)
- `db_port`: Database port (optional, defaults to 3306)
- `db_user`: Database username
- `db_pass`: Database password  
- `db_name`: WordPress database name

---

## 🚀 Usage

### Two-Phase Workflow

#### Phase 1: Preprocessing
```bash
# Generate matches (dry run with limited results)
python preprocess_media.py --limit=5 --verbose

# Generate all matches
python preprocess_media.py
```

#### Phase 2: Application
```bash
# Dry run (show what would be applied)
python apply_terms_direct.py --dry-run

# Apply changes to database
python apply_terms_direct.py

# Apply with backup
python apply_terms_direct.py --backup
```

### Command Line Options

#### preprocess_media.py
- `--config=FILE` - Path to configuration file (default: config.yml)
- `--limit=N` - Process only the first N attachments (useful for testing)
- `--verbose` - Display detailed processing output

#### apply_terms_direct.py
- `--dry-run` - Show what would be done, no database writes
- `--export` - Generate CSV log only, no changes
- `--backup` - Run `wp db export` before modifying database
- `--verbose` - Enable verbose output
- `--config=FILE` - Path to configuration file (default: config.yml)

### Examples

```bash
# Complete workflow with testing
python preprocess_media.py --limit=10 --verbose
python apply_terms_direct.py --dry-run --verbose

# Production workflow with backup
python preprocess_media.py
python apply_terms_direct.py --backup

# Generate CSV report only
python preprocess_media.py
python apply_terms_direct.py --export
```

---

## ⚡ Performance & Architecture

### Pure Python Implementation
- **Fast processing**: Direct database access eliminates wp-cli overhead for term operations
- **Batch operations**: Efficient bulk inserts for relationships and term creation
- **Transaction safety**: All database changes are wrapped in transactions with rollback support
- **Caching**: Existing terms and relationships are cached for optimal performance

### Database Operations
- **Direct MySQL access**: Uses pymysql for efficient database operations
- **Hierarchical terms**: Properly handles parent-child term relationships
- **Relationship management**: Batch inserts new term assignments, skips existing ones
- **Count updates**: Automatically maintains accurate term usage counts
- **Cache invalidation**: Flushes WordPress cache after database changes

---

## 🔧 Troubleshooting

### Database Connection Issues
If you get database connection errors:

```bash
# Test your database credentials
mysql -h localhost -u wp_user -p wp_database

# Check your config.yml database settings
# Ensure the database user has proper permissions
```

### Virtual Environment Issues
If you encounter issues with the virtual environment:

```bash
# Ensure python3-venv is installed (Ubuntu/Debian)
sudo apt-get install python3-venv

# Or use the --user flag for global installation
python3 -m pip install --user pyyaml pymysql

# Check Python version (requires 3.8+)
python3 --version
```

### Permission Issues
If you get permission errors:

```bash
# For global installation, try user installation
python3 -m pip install --user pyyaml pymysql

# Or use virtual environment (recommended)
./install-deps.sh
```

### WordPress Connection Issues
If the preprocessor can't connect to WordPress:

- Ensure `wp-cli` is installed and working: `wp --info`
- Check that the `wp_path` in `config.yml` is correct
- Verify the `media_category` taxonomy exists in your WordPress installation

---

## 🧪 Notes

- **Filename matching**: Case-insensitive matching against keywords
- **Multiple matches**: Files can match multiple keywords, all applicable terms are assigned
- **Hierarchical terms**: Terms are created with proper parent-child relationships
- **Duplicate prevention**: Existing term relationships are preserved, no duplicates created
- **Transaction safety**: All database operations use transactions with rollback on error
- **CSV logging**: Detailed logs of all operations for audit and troubleshooting
- **Regex support**: Use `regex: true` in mappings for pattern-based matching
- **Taxonomy modes**: 
  - `all`: Assign all terms in hierarchy (e.g., both "Wedding" and "Portraits")
  - `children_only`: Assign only parent terms that have children
  - `bottom_only`: Assign only the deepest terms in each hierarchy

---

## 🔄 Migration from Bash Version

If you're upgrading from the previous Bash+Python hybrid:

1. **Database credentials**: Add `db_host`, `db_user`, `db_pass`, `db_name` to your `config.yml`
2. **New workflow**: Replace `./categorize-media.sh --apply` with the two-phase Python workflow
3. **Same functionality**: All features (dry-run, backup, CSV logging, taxonomy modes) work identically
4. **Performance improvement**: Expect significantly faster execution due to direct database access

---

## 💥 Disclaimer

This script is provided for use in development and staging environments. Always backup your database before making changes. The tool includes built-in backup functionality, but you should also maintain your own backup strategy.

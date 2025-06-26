# Media Categorizer

A utility script for programmatically assigning custom taxonomy terms to WordPress media library items (attachments), based on filename keyword matches.

This tool is designed for use in local or staging environments where automated taxonomy tagging can save time and enforce consistency.

---

## 🔧 Requirements

- WordPress CLI (`wp`) must be installed and available in your shell
- `yq` must be installed (for parsing YAML)
- `jq` must be installed (for JSON parsing when using Python preprocessor)
- **Python 3.8+** and PyYAML (for fast preprocessing - install with `pip install pyyaml`)
- The WordPress installation must be accessible and functioning
- A custom taxonomy named `media_category` must already be registered
- Bash 3.2+ is required. On macOS, the default bash version is sufficient.

---

## 📁 Project Structure

```
media-categorizer/
├── categorize-media.sh      # Main script
├── preprocess_media.py      # Python preprocessor for fast matching
├── config.yml               # Keyword mapping & settings
└── README.md                # This file
```

---

## 🧠 How it Works

The script:

1. Parses `config.yml` to read:
   - Your WordPress install location
   - Keyword-to-taxonomy mappings (e.g., filenames containing "Formals" → "Wedding > Portraits")
   - Taxonomy assignment mode (all terms, only children, or just bottom-most)
   - Backup settings
2. Runs a **dry run** by default:
   - Lists which attachments will be affected
   - Shows the matched keywords and target taxonomy terms
   - Warns about any missing terms
3. Prompts to create missing terms, with correct parent-child structure
4. If run with `--apply`, actually applies changes and creates backup if enabled

---

## 📝 config.yml Format

The top-level keys under `mappings` are only labels for organizational purposes. They do not affect the logic. You can name them anything you like — they are not used for matching.

```yaml
settings:
  wp_path: /path/to/wordpress
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

---

## 🚀 Usage

### Dry run (default):

```bash
./categorize-media.sh
```

### Apply changes:

```bash
./categorize-media.sh --apply
```

### Optional Flags:

- `--apply` - Actually assign taxonomy terms and create missing terms if confirmed
- `--no-prompt` - Suppress interactive prompts (auto-create missing terms if needed)
- `--limit=N` - Process only the first N matching attachments (useful for testing)
- `--export` - Skip all changes and output results as CSV only (dry-run + log)
- `--preprocess` - Use Python preprocessor for fast matching (default: true)
- `--no-preprocess` - Use legacy Bash matching (slower but no Python required)
- `--keep-temp` - Keep temporary matches.json file for debugging
- `--verbose` - Display detailed processing output for debugging and review
- `--no-color` - Disable colored terminal output
- `-h, --help` - Show usage information

### Examples:

```bash
# Dry run with verbose output
./categorize-media.sh --verbose

# Apply changes with prompts
./categorize-media.sh --apply

# Apply changes without prompts
./categorize-media.sh --apply --no-prompt

# Generate CSV report only
./categorize-media.sh --export

# Process first 10 attachments with details
./categorize-media.sh --limit=10 --verbose
```

---

## ⚡ Performance Optimization

The script now includes a **two-phase architecture** for dramatically improved performance:

### Python Preprocessor (Default)
- **Fast matching**: Uses Python's compiled regex and efficient string operations
- **Single wp-cli call**: Fetches all attachments at once instead of multiple queries
- **Massive speedup**: ~30-45x faster for large media libraries (18k files: ~1.5h → ~2-3min)
- **Automatic**: Enabled by default with `--preprocess` (or `--preprocess=true`)

### Legacy Bash Mode
- **Fallback option**: Use `--no-preprocess` if Python is unavailable
- **Same results**: Identical matching logic and output
- **Slower**: Line-by-line processing in Bash (original performance)

### Requirements for Fast Mode
```bash
# Install Python dependencies
pip install pyyaml

# Ensure jq is available for JSON parsing
brew install jq  # macOS
# or apt-get install jq  # Ubuntu/Debian
```

---

## 🧪 Notes

- Filenames are matched case-insensitively against keywords
- The script only scans media items (post_type=attachment)
- Files can match multiple keywords, and all applicable taxonomy terms will be assigned
- Terms are created if missing, unless declined during prompt
- Hierarchical terms are respected and created in order if necessary
- Term existence checks are cached for performance — the script avoids duplicate `wp term list` calls
- When `--apply` is used, the script generates a simple CSV log of changes (attachments updated and terms created)
- If multiple keywords match the same taxonomy term, that term is only assigned once per attachment
- Terminal color output is enabled by default for readability. Use `--no-color` to disable it
- Regex-based matching is supported. Use `regex: true` under a mapping entry to match filenames with regular expressions
- The `--export` flag behaves like a dry run, but outputs results to CSV without applying any changes or prompting
- Use `--verbose` to print extra details during processing, including matched keywords, term assignments, and creation events
- You can customize the location of the CSV output log with `settings.output_csv_path` in your config file

---

## 💥 Disclaimer

This script is provided for use in development and staging environments. Do not run this in production without understanding the consequences. Back up your database before making changes.

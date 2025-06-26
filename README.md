# Media Categorizer

A utility script for programmatically assigning custom taxonomy terms to WordPress media library items (attachments), based on filename keyword matches.

This tool is designed for use in local or staging environments where automated taxonomy tagging can save time and enforce consistency.

---

## 🔧 Requirements

- WordPress CLI (`wp`) must be installed and available in your shell
- `yq` must be installed (for parsing YAML)
- The WordPress installation must be accessible and functioning
- A custom taxonomy named `media_category` must already be registered

---

## 📁 Project Structure

media-categorizer/
├── categorize-media.sh      # Main script
├── config.yml               # Keyword mapping & settings
└── README.md                # This file

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

```yaml
settings:
  wp_path: /path/to/wordpress
  apply_taxonomy:
    mode: all  # Options: all, children_only, bottom_only
  backup:
    enabled: true
    output_path: ./backups/media-categorizer-$(date +%F_%H-%M-%S).sql

mappings:
  Formals:
    - Wedding > Portraits
  Candids:
    - Wedding > Preparations
  Ceremony:
    - Wedding > Ceremony
  Details:
    - Wedding > Details
  Party:
    - Wedding > Party
  Portfolio:
    - Portfolio


⸻

🚀 Usage

Dry run (default):

./categorize-media.sh

Apply changes:

./categorize-media.sh --apply


⸻

🧪 Notes
	•	Filenames are matched case-insensitively against keywords.
	•	The script only scans media items (post_type=attachment).
	•	Files can match multiple keywords, and all applicable taxonomy terms will be assigned.
	•	Terms are created if missing, unless declined during prompt.
	•	Hierarchical terms are respected and created in order if necessary.

⸻

💥 Disclaimer

This script is provided for use in development and staging environments. Do not run this in production without understanding the consequences. Back up your database before making changes.
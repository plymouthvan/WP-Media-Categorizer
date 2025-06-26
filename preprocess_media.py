#!/usr/bin/env python3
"""
Media Categorizer Pre-processor
Fetches WordPress attachments and processes keyword matches for fast taxonomy assignment.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("Error: PyYAML is required. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


def parse_args():
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(
        description="Pre-process WordPress media attachments for taxonomy assignment"
    )
    parser.add_argument(
        "--config",
        default="config.yml",
        help="Path to configuration file (default: config.yml)"
    )
    parser.add_argument(
        "--limit",
        type=int,
        help="Limit number of attachments to process"
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable verbose output"
    )
    return parser.parse_args()


def load_config(config_path):
    """Load and validate configuration from YAML file."""
    if not os.path.exists(config_path):
        print(f"Error: Configuration file not found: {config_path}", file=sys.stderr)
        sys.exit(1)
    
    try:
        with open(config_path, 'r') as f:
            config = yaml.safe_load(f)
    except yaml.YAMLError as e:
        print(f"Error: Invalid YAML in {config_path}: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error: Cannot read {config_path}: {e}", file=sys.stderr)
        sys.exit(1)
    
    # Validate required settings
    if not config.get('settings', {}).get('wp_path'):
        print("Error: settings.wp_path is required in configuration", file=sys.stderr)
        sys.exit(1)
    
    if not config.get('mappings'):
        print("Error: No mappings defined in configuration", file=sys.stderr)
        sys.exit(1)
    
    return config


def fetch_attachments(config, limit=None, verbose=False):
    """Fetch WordPress attachments using wp-cli."""
    wp_path = config['settings']['wp_path']
    
    if not os.path.exists(wp_path):
        print(f"Error: WordPress path does not exist: {wp_path}", file=sys.stderr)
        sys.exit(1)
    
    # Build wp-cli command
    cmd = [
        "wp", "post", "list",
        "--post_type=attachment",
        "--format=json",
        "--fields=ID,post_title,guid"
    ]
    
    if limit:
        cmd.append(f"--posts_per_page={limit}")
    
    if verbose:
        print(f"Executing: {' '.join(cmd)}")
        print(f"Working directory: {wp_path}")
    
    try:
        result = subprocess.run(
            cmd,
            cwd=wp_path,
            capture_output=True,
            text=True,
            check=True
        )
    except subprocess.CalledProcessError as e:
        print(f"Error: wp-cli command failed: {e}", file=sys.stderr)
        print(f"Command: {' '.join(cmd)}", file=sys.stderr)
        if e.stderr:
            print(f"wp-cli error: {e.stderr}", file=sys.stderr)
        sys.exit(1)
    except FileNotFoundError:
        print("Error: wp-cli not found. Please install WordPress CLI", file=sys.stderr)
        sys.exit(1)
    
    try:
        attachments = json.loads(result.stdout)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON from wp-cli: {e}", file=sys.stderr)
        sys.exit(1)
    
    if verbose:
        print(f"Fetched {len(attachments)} attachments")
    
    return attachments


def match_filename(filename, mapping):
    """Check if filename matches a mapping pattern."""
    if mapping.get("regex", False):
        try:
            pattern = re.compile(mapping["match"], re.IGNORECASE)
            return pattern.search(filename) is not None
        except re.error as e:
            print(f"Warning: Invalid regex pattern '{mapping['match']}': {e}", file=sys.stderr)
            return False
    else:
        return mapping["match"].lower() in filename.lower()


def process_matches(attachments, mappings, verbose=False):
    """Process attachments and find keyword matches."""
    matches = {}
    
    for attachment in attachments:
        attachment_id = str(attachment["ID"])
        filename = os.path.basename(attachment["guid"])
        title = attachment.get("post_title", "")
        
        matched_terms = set()
        
        if verbose:
            print(f"Processing: {filename} (ID: {attachment_id})")
        
        # Check each mapping
        for mapping_key, mapping in mappings.items():
            if match_filename(filename, mapping):
                if verbose:
                    print(f"  ✓ Matched keyword: \"{mapping['match']}\"")
                
                # Add all terms from this mapping
                for term in mapping.get("terms", []):
                    matched_terms.add(term)
                    if verbose:
                        print(f"    → {term}")
        
        # Only include attachments with matches
        if matched_terms:
            matches[attachment_id] = {
                "filename": filename,
                "title": title,
                "terms": sorted(list(matched_terms))
            }
        elif verbose:
            print(f"  No matches for: {filename}")
    
    return matches


def write_matches_json(matches, output_path="tmp/matches.json"):
    """Write matches to JSON file."""
    # Ensure output directory exists
    output_dir = os.path.dirname(output_path)
    if output_dir and not os.path.exists(output_dir):
        try:
            os.makedirs(output_dir)
        except OSError as e:
            print(f"Error: Cannot create directory {output_dir}: {e}", file=sys.stderr)
            sys.exit(2)
    
    try:
        with open(output_path, 'w') as f:
            json.dump(matches, f, indent=2, sort_keys=True)
    except Exception as e:
        print(f"Error: Cannot write to {output_path}: {e}", file=sys.stderr)
        sys.exit(2)


def print_summary(total_attachments, matches_count):
    """Print processing summary."""
    print(f"Total attachments processed: {total_attachments}")
    print(f"Attachments with matches: {matches_count}")
    if matches_count > 0:
        print(f"Results written to: tmp/matches.json")


def main():
    """Main execution function."""
    args = parse_args()
    
    # Load configuration
    config = load_config(args.config)
    
    # Fetch attachments
    attachments = fetch_attachments(config, args.limit, args.verbose)
    
    # Process matches
    matches = process_matches(attachments, config["mappings"], args.verbose)
    
    # Write results (always write file, even if empty)
    write_matches_json(matches)
    
    # Print summary
    print_summary(len(attachments), len(matches))
    
    return 0


if __name__ == "__main__":
    sys.exit(main())

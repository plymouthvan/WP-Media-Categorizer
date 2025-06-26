#!/usr/bin/env python3
"""
WordPress Media Categorizer - Direct Database Application
Applies taxonomy terms to media attachments by writing directly to MySQL database.
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

try:
    import yaml
    import pymysql
except ImportError as e:
    print(f"Error: Required package missing: {e}", file=sys.stderr)
    print("Install with: pip install pyyaml pymysql", file=sys.stderr)
    sys.exit(1)


class MediaCategorizer:
    """Main class for applying taxonomy terms to WordPress media."""
    
    def __init__(self, config_path="config.yml", verbose=False):
        self.config_path = config_path
        self.verbose = verbose
        self.config = None
        self.db_connection = None
        self.taxonomy_name = "media_category"
        
        # Caches for performance
        self.term_cache = {}  # term_name -> term_id
        self.term_taxonomy_cache = {}  # term_id -> term_taxonomy_id
        self.existing_relationships = set()  # (object_id, term_taxonomy_id) tuples
        
        # Tracking for logging
        self.created_terms = []  # [(term_name, term_id), ...]
        self.assigned_relationships = {}  # attachment_id -> [term_names]
        self.assignment_errors = []  # [(attachment_id, error_msg), ...]
    
    def log_info(self, message):
        """Log informational message."""
        print(f"ℹ {message}")
    
    def log_success(self, message):
        """Log success message."""
        print(f"✓ {message}")
    
    def log_error(self, message):
        """Log error message."""
        print(f"✗ {message}", file=sys.stderr)
    
    def log_warning(self, message):
        """Log warning message."""
        print(f"⚠ {message}")
    
    def log_verbose(self, message):
        """Log verbose message if verbose mode is enabled."""
        if self.verbose:
            print(f"→ {message}")
    
    def load_config(self):
        """Load and validate configuration from YAML file."""
        if not os.path.exists(self.config_path):
            self.log_error(f"Configuration file not found: {self.config_path}")
            sys.exit(1)
        
        try:
            with open(self.config_path, 'r') as f:
                self.config = yaml.safe_load(f)
        except yaml.YAMLError as e:
            self.log_error(f"Invalid YAML in {self.config_path}: {e}")
            sys.exit(1)
        except Exception as e:
            self.log_error(f"Cannot read {self.config_path}: {e}")
            sys.exit(1)
        
        # Validate required settings
        settings = self.config.get('settings', {})
        required_db_fields = ['db_host', 'db_user', 'db_pass', 'db_name']
        
        for field in required_db_fields:
            if not settings.get(field):
                self.log_error(f"Required database setting missing: settings.{field}")
                sys.exit(1)
        
        self.log_verbose("Configuration loaded successfully")
    
    def connect_database(self):
        """Connect to MySQL database using configuration credentials."""
        settings = self.config['settings']
        
        # Build connection parameters
        connection_params = {
            'host': settings['db_host'],
            'user': settings['db_user'],
            'password': settings['db_pass'],
            'database': settings['db_name'],
            'charset': 'utf8mb4',
            'cursorclass': pymysql.cursors.DictCursor,
            'autocommit': False
        }
        
        # Add port if specified, or use socket if specified
        if settings.get('db_socket'):
            # Use Unix socket connection (common with MAMP)
            connection_params['unix_socket'] = settings['db_socket']
            # Remove host when using socket
            del connection_params['host']
            connection_string = f"{settings['db_name']}@socket:{settings['db_socket']}"
        elif settings.get('db_port'):
            connection_params['port'] = int(settings['db_port'])
            connection_string = f"{settings['db_name']}@{settings['db_host']}:{settings['db_port']}"
        else:
            connection_string = f"{settings['db_name']}@{settings['db_host']}"
        
        try:
            self.db_connection = pymysql.connect(**connection_params)
            self.log_verbose(f"Connected to database: {connection_string}")
        except pymysql.Error as e:
            self.log_error(f"Database connection failed: {e}")
            sys.exit(1)
    
    def cache_existing_data(self):
        """Cache existing terms, term_taxonomy, and relationships for performance."""
        self.log_verbose("Caching existing taxonomy data...")
        
        try:
            with self.db_connection.cursor() as cursor:
                # Cache terms
                cursor.execute("SELECT term_id, name, slug FROM wp_terms")
                for row in cursor.fetchall():
                    term_id = row['term_id']
                    # Cache by name, slug, and lowercase versions
                    self.term_cache[row['name']] = term_id
                    self.term_cache[row['slug']] = term_id
                    self.term_cache[row['name'].lower()] = term_id
                    self.term_cache[row['slug'].lower()] = term_id
                
                # Cache term_taxonomy for media_category
                cursor.execute(
                    "SELECT term_taxonomy_id, term_id FROM wp_term_taxonomy WHERE taxonomy = %s",
                    (self.taxonomy_name,)
                )
                for row in cursor.fetchall():
                    self.term_taxonomy_cache[row['term_id']] = row['term_taxonomy_id']
                
                # Cache existing relationships
                cursor.execute("SELECT object_id, term_taxonomy_id FROM wp_term_relationships")
                for row in cursor.fetchall():
                    self.existing_relationships.add((row['object_id'], row['term_taxonomy_id']))
                
                self.log_verbose(f"Cached {len(self.term_cache)//4} terms, {len(self.term_taxonomy_cache)} taxonomy entries, {len(self.existing_relationships)} relationships")
        
        except pymysql.Error as e:
            self.log_error(f"Failed to cache existing data: {e}")
            sys.exit(1)
    
    def load_matches(self, matches_file="tmp/matches.json"):
        """Load matches from JSON file created by preprocess_media.py."""
        if not os.path.exists(matches_file):
            self.log_error(f"Matches file not found: {matches_file}")
            self.log_error("Run preprocess_media.py first to generate matches")
            sys.exit(1)
        
        try:
            with open(matches_file, 'r') as f:
                matches = json.load(f)
        except json.JSONDecodeError as e:
            self.log_error(f"Invalid JSON in {matches_file}: {e}")
            sys.exit(1)
        except Exception as e:
            self.log_error(f"Cannot read {matches_file}: {e}")
            sys.exit(1)
        
        if not matches:
            self.log_info("No matches found in preprocessor results")
            return {}
        
        self.log_success(f"Loaded {len(matches)} attachments with matches")
        return matches
    
    def parse_term_hierarchy(self, term_path):
        """Parse hierarchical term path (e.g., 'Wedding > Portraits') into parts."""
        return [part.strip() for part in term_path.split('>')]
    
    def get_term_id(self, term_name):
        """Get term ID by name, trying various case combinations."""
        # Try exact match first
        if term_name in self.term_cache:
            return self.term_cache[term_name]
        
        # Try lowercase
        lower_name = term_name.lower()
        if lower_name in self.term_cache:
            return self.term_cache[lower_name]
        
        return None
    
    def create_term(self, term_name, parent_id=None, dry_run=False):
        """Create a new term in wp_terms and wp_term_taxonomy."""
        if dry_run:
            self.log_verbose(f"[DRY RUN] Would create term: {term_name} (parent: {parent_id or 'none'})")
            # Return a fake ID for dry run
            fake_id = len(self.term_cache) + 1000
            return fake_id
        
        try:
            with self.db_connection.cursor() as cursor:
                # Create slug from name
                slug = term_name.lower().replace(' ', '-').replace('&', 'and')
                
                # Insert into wp_terms
                cursor.execute(
                    "INSERT INTO wp_terms (name, slug) VALUES (%s, %s)",
                    (term_name, slug)
                )
                term_id = cursor.lastrowid
                
                # Insert into wp_term_taxonomy
                cursor.execute(
                    "INSERT INTO wp_term_taxonomy (term_id, taxonomy, parent, count) VALUES (%s, %s, %s, 0)",
                    (term_id, self.taxonomy_name, parent_id or 0)
                )
                term_taxonomy_id = cursor.lastrowid
                
                # Update caches
                self.term_cache[term_name] = term_id
                self.term_cache[slug] = term_id
                self.term_cache[term_name.lower()] = term_id
                self.term_taxonomy_cache[term_id] = term_taxonomy_id
                
                # Track for logging
                self.created_terms.append((term_name, term_id))
                
                self.log_verbose(f"Created term: {term_name} (ID: {term_id})")
                return term_id
        
        except pymysql.Error as e:
            self.log_error(f"Failed to create term '{term_name}': {e}")
            raise
    
    def ensure_term_hierarchy(self, term_path, dry_run=False):
        """Ensure all terms in a hierarchical path exist, creating if necessary."""
        term_parts = self.parse_term_hierarchy(term_path)
        parent_id = None
        
        for term_name in term_parts:
            term_id = self.get_term_id(term_name)
            
            if term_id is None:
                # Term doesn't exist, create it
                term_id = self.create_term(term_name, parent_id, dry_run)
            
            parent_id = term_id
        
        return parent_id  # Return the final (deepest) term ID
    
    def filter_terms_by_mode(self, term_paths):
        """Filter terms based on taxonomy mode setting."""
        mode = self.config.get('settings', {}).get('apply_taxonomy', {}).get('mode', 'all')
        
        if mode == 'all':
            # Expand hierarchical paths into individual terms
            all_terms = set()
            for term_path in term_paths:
                term_parts = self.parse_term_hierarchy(term_path)
                all_terms.update(term_parts)
            return list(all_terms)
        
        elif mode == 'children_only':
            # Return only terms that have children (not leaf terms)
            children_terms = set()
            for term_path in term_paths:
                # Check if this term path has a child in the list
                for other_path in term_paths:
                    if other_path != term_path and other_path.startswith(term_path + ' > '):
                        # This term has children, add the bottom-most part
                        bottom_term = term_path.split(' > ')[-1]
                        children_terms.add(bottom_term)
                        break
            return list(children_terms)
        
        elif mode == 'bottom_only':
            # Return only leaf terms (deepest in hierarchy)
            leaf_terms = set()
            for term_path in term_paths:
                # Check if this is a leaf (no other term starts with this + ' > ')
                is_leaf = True
                for other_path in term_paths:
                    if other_path != term_path and other_path.startswith(term_path + ' > '):
                        is_leaf = False
                        break
                
                if is_leaf:
                    # Extract the bottom-most term
                    bottom_term = term_path.split(' > ')[-1]
                    leaf_terms.add(bottom_term)
            
            return list(leaf_terms)
        
        else:
            self.log_error(f"Invalid taxonomy mode: {mode}")
            sys.exit(1)
    
    def get_term_taxonomy_id(self, term_name):
        """Get term_taxonomy_id for a term name."""
        term_id = self.get_term_id(term_name)
        if term_id is None:
            return None
        
        return self.term_taxonomy_cache.get(term_id)
    
    def assign_terms_to_attachment(self, attachment_id, term_names, dry_run=False):
        """Assign terms to an attachment, creating relationships."""
        if dry_run:
            self.log_verbose(f"[DRY RUN] Would assign terms to attachment {attachment_id}: {', '.join(term_names)}")
            return
        
        assigned_terms = []
        new_relationships = []
        
        for term_name in term_names:
            term_taxonomy_id = self.get_term_taxonomy_id(term_name)
            
            if term_taxonomy_id is None:
                error_msg = f"Term not found: {term_name}"
                self.assignment_errors.append((attachment_id, error_msg))
                self.log_error(f"Attachment {attachment_id}: {error_msg}")
                continue
            
            # Check if relationship already exists
            if (attachment_id, term_taxonomy_id) in self.existing_relationships:
                self.log_verbose(f"Relationship already exists: attachment {attachment_id} -> term {term_name}")
                continue
            
            new_relationships.append((attachment_id, term_taxonomy_id))
            assigned_terms.append(term_name)
            self.log_verbose(f"Will assign term '{term_name}' to attachment {attachment_id}")
        
        if new_relationships:
            try:
                with self.db_connection.cursor() as cursor:
                    # Batch insert relationships
                    cursor.executemany(
                        "INSERT INTO wp_term_relationships (object_id, term_taxonomy_id) VALUES (%s, %s)",
                        new_relationships
                    )
                    
                    # Update term counts
                    for _, term_taxonomy_id in new_relationships:
                        cursor.execute(
                            "UPDATE wp_term_taxonomy SET count = count + 1 WHERE term_taxonomy_id = %s",
                            (term_taxonomy_id,)
                        )
                    
                    # Update caches
                    for relationship in new_relationships:
                        self.existing_relationships.add(relationship)
                    
                    self.log_verbose(f"Assigned {len(new_relationships)} new terms to attachment {attachment_id}")
            
            except pymysql.Error as e:
                error_msg = f"Database error assigning terms: {e}"
                self.assignment_errors.append((attachment_id, error_msg))
                self.log_error(f"Attachment {attachment_id}: {error_msg}")
                return
        
        # Track for logging
        if assigned_terms:
            self.assigned_relationships[attachment_id] = assigned_terms
    
    def create_backup(self):
        """Create database backup using wp-cli."""
        if not self.config.get('settings', {}).get('backup', {}).get('enabled', False):
            return
        
        backup_path = self.config['settings']['backup']['output_path']
        wp_path = self.config['settings']['wp_path']
        
        # Expand date substitution
        import subprocess
        expanded_path = subprocess.check_output(
            f'echo "{backup_path}"', 
            shell=True, 
            text=True
        ).strip()
        
        # Ensure backup directory exists
        backup_dir = os.path.dirname(expanded_path)
        if backup_dir and not os.path.exists(backup_dir):
            os.makedirs(backup_dir)
        
        self.log_info("Creating database backup...")
        
        try:
            subprocess.run(
                ["wp", "db", "export", expanded_path],
                cwd=wp_path,
                check=True,
                capture_output=True
            )
            self.log_success(f"Database backup created: {expanded_path}")
        except subprocess.CalledProcessError as e:
            self.log_error(f"Failed to create database backup: {e}")
            sys.exit(1)
    
    def flush_cache(self):
        """Flush WordPress cache using wp-cli."""
        wp_path = self.config['settings']['wp_path']
        
        try:
            subprocess.run(
                ["wp", "cache", "flush"],
                cwd=wp_path,
                check=True,
                capture_output=True
            )
            self.log_verbose("WordPress cache flushed")
        except subprocess.CalledProcessError as e:
            self.log_warning(f"Failed to flush cache: {e}")
    
    def generate_csv_log(self, mode="apply"):
        """Generate CSV log of operations."""
        csv_path = self.config.get('settings', {}).get('output_csv_path', './logs/media-categorizer-log.csv')
        
        # Expand date substitution
        import subprocess
        expanded_path = subprocess.check_output(
            f'echo "{csv_path}"', 
            shell=True, 
            text=True
        ).strip()
        
        # Ensure directory exists
        csv_dir = os.path.dirname(expanded_path)
        if csv_dir and not os.path.exists(csv_dir):
            os.makedirs(csv_dir)
        
        self.log_verbose(f"Writing CSV log to: {expanded_path}")
        
        try:
            with open(expanded_path, 'w') as f:
                # Write header
                f.write("attachment_id,filename,matched_keywords,terms_assigned,terms_created,timestamp\n")
                
                # Load matches for reference
                matches = self.load_matches()
                timestamp = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
                
                for attachment_id, match_data in matches.items():
                    filename = match_data['filename']
                    matched_keywords = "preprocessed"  # From Python preprocessor
                    
                    # Get assigned terms
                    assigned_terms = self.assigned_relationships.get(int(attachment_id), [])
                    terms_assigned = ','.join(assigned_terms)
                    
                    # Get created terms (all created terms, not per-attachment)
                    created_terms = ','.join([name for name, _ in self.created_terms])
                    
                    # Escape quotes in CSV fields
                    filename = filename.replace('"', '""')
                    matched_keywords = matched_keywords.replace('"', '""')
                    terms_assigned = terms_assigned.replace('"', '""')
                    created_terms = created_terms.replace('"', '""')
                    
                    f.write(f'{attachment_id},"{filename}","{matched_keywords}","{terms_assigned}","{created_terms}",{timestamp}\n')
            
            self.log_success(f"Results logged to: {expanded_path}")
        
        except Exception as e:
            self.log_error(f"Failed to write CSV log: {e}")
    
    def display_dry_run_summary(self, matches):
        """Display dry run summary table."""
        if not matches:
            self.log_info("No attachments matched any keywords")
            return
        
        print()
        print("DRY RUN SUMMARY")
        print("=" * 80)
        print(f"{'ID':<8} {'FILENAME':<30} {'MATCHED KEYWORDS':<20} {'TAXONOMY TERMS':<30}")
        print("=" * 80)
        
        for attachment_id, match_data in matches.items():
            filename = match_data['filename']
            terms = match_data['terms']
            
            # Apply taxonomy mode filtering
            filtered_terms = self.filter_terms_by_mode(terms)
            
            # Truncate long values for display
            if len(filename) > 28:
                filename = filename[:25] + "..."
            
            terms_str = ','.join(filtered_terms)
            if len(terms_str) > 28:
                terms_str = terms_str[:25] + "..."
            
            print(f"{attachment_id:<8} {filename:<30} {'preprocessed':<20} {terms_str:<30}")
        
        print("=" * 80)
        print()
        self.log_info("This was a dry run. Run without --dry-run to apply changes.")
    
    def process_matches(self, matches, dry_run=False):
        """Process all matches and apply taxonomy assignments."""
        if not matches:
            self.log_info("No matches to process")
            return
        
        # Ensure all required terms exist
        all_term_paths = set()
        for match_data in matches.values():
            all_term_paths.update(match_data['terms'])
        
        self.log_info("Analyzing required taxonomy terms...")
        for term_path in all_term_paths:
            self.ensure_term_hierarchy(term_path, dry_run)
        
        if self.created_terms and not dry_run:
            self.log_success(f"Created {len(self.created_terms)} new terms")
        
        # Apply taxonomy assignments
        self.log_info("Applying taxonomy assignments...")
        total_assignments = 0
        successful_assignments = 0
        
        for attachment_id, match_data in matches.items():
            attachment_id = int(attachment_id)
            terms = match_data['terms']
            
            # Filter terms based on taxonomy mode
            filtered_terms = self.filter_terms_by_mode(terms)
            
            if not filtered_terms:
                continue
            
            total_assignments += len(filtered_terms)
            
            # Assign terms to attachment
            self.assign_terms_to_attachment(attachment_id, filtered_terms, dry_run)
            
            if attachment_id in self.assigned_relationships:
                successful_assignments += len(self.assigned_relationships[attachment_id])
        
        if not dry_run:
            self.log_success(f"Applied {successful_assignments} of {total_assignments} taxonomy assignments")
            
            # Report errors
            if self.assignment_errors:
                self.log_warning(f"{len(self.assignment_errors)} assignments failed:")
                for attachment_id, error_msg in self.assignment_errors:
                    self.log_warning(f"  Attachment {attachment_id}: {error_msg}")
    
    def run(self, dry_run=False, export_only=False, backup=False):
        """Main execution method."""
        # Load configuration and connect to database
        self.load_config()
        self.connect_database()
        
        # Cache existing data
        self.cache_existing_data()
        
        # Load matches from preprocessor
        matches = self.load_matches()
        
        if export_only:
            self.log_info("Running in export mode (CSV output only)...")
            self.generate_csv_log("export")
            self.log_info("Export complete. No changes were made to WordPress.")
            return
        
        if dry_run:
            self.log_info("Running in dry run mode...")
            self.display_dry_run_summary(matches)
            return
        
        # Live apply mode
        self.log_info("Running in apply mode...")
        
        # Create backup if requested
        if backup:
            self.create_backup()
        
        try:
            # Process matches and apply changes
            self.process_matches(matches, dry_run=False)
            
            # Commit all changes
            self.db_connection.commit()
            
            # Flush WordPress cache
            self.flush_cache()
            
            # Generate CSV log
            self.generate_csv_log("apply")
            
            self.log_success("Apply mode completed successfully")
        
        except Exception as e:
            # Rollback on error
            self.db_connection.rollback()
            self.log_error(f"Operation failed, changes rolled back: {e}")
            sys.exit(1)
        
        finally:
            if self.db_connection:
                self.db_connection.close()


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Apply taxonomy terms to WordPress media attachments via direct database access"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be done, no database writes"
    )
    parser.add_argument(
        "--export",
        action="store_true",
        help="Generate CSV log only, no changes"
    )
    parser.add_argument(
        "--backup",
        action="store_true",
        help="Run 'wp db export' before modifying database"
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable verbose output"
    )
    parser.add_argument(
        "--config",
        default="config.yml",
        help="Path to configuration file (default: config.yml)"
    )
    
    args = parser.parse_args()
    
    # Create and run categorizer
    categorizer = MediaCategorizer(args.config, args.verbose)
    categorizer.run(
        dry_run=args.dry_run,
        export_only=args.export,
        backup=args.backup
    )


if __name__ == "__main__":
    main()

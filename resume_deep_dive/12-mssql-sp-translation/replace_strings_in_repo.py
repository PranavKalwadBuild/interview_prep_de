import os
import subprocess
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
logger = logging.getLogger(__name__)

# Systematic T-SQL → Snowflake replacement patterns discovered through error log analysis.
# Each entry: "T-SQL pattern" → "Snowflake equivalent"
# Add new patterns here when the log table shows repeated failures for the same token.
REPLACEMENTS = {
    "@@ROWCOUNT":        "SQLROWCOUNT",
    "@@ERROR":           "SQLCODE",
    "NOCOUNT ON":        "",
    "NOCOUNT OFF":       "",
    "SET NOCOUNT":       "-- SET NOCOUNT",
    "GETDATE()":         "CURRENT_TIMESTAMP()",
    "ISNULL(":           "COALESCE(",
    "LEN(":              "LENGTH(",
    "TOP ":              "",             # handled separately — Snowflake uses LIMIT
    "NVARCHAR":          "VARCHAR",
    "DATETIME":          "TIMESTAMP_NTZ",
    "BIT":               "BOOLEAN",
    "##":                "-- TEMP_TABLE: ",  # global temp tables need manual review
}


def pull_latest(repo_dir: str):
    """Ensure we work on the latest version of the translated repo."""
    logger.info(f"[GIT] Pulling latest changes in {repo_dir}")
    result = subprocess.run(["git", "pull"], cwd=repo_dir, capture_output=True, text=True)
    if result.returncode != 0:
        logger.warning(f"[GIT] git pull warning: {result.stderr.strip()}")
    else:
        logger.info(f"[GIT] {result.stdout.strip()}")


def replace_in_file(fpath: str, replacements: dict) -> int:
    """Apply all replacements to a single file. Returns count of changes made."""
    with open(fpath, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()

    original = content
    total_changes = 0
    for old, new in replacements.items():
        count = content.count(old)
        if count:
            content = content.replace(old, new)
            total_changes += count
            logger.info(f"  [{os.path.basename(fpath)}] '{old}' → '{new}' ({count}x)")

    if total_changes:
        with open(fpath, "w", encoding="utf-8") as f:
            f.write(content)

    return total_changes


def replace_in_repo(repo_dir: str, replacements: dict = REPLACEMENTS):
    """Walk all .sql files in repo_dir and apply all replacements."""
    pull_latest(repo_dir)

    total_files = 0
    total_changes = 0

    for root, _, files in os.walk(repo_dir):
        for fname in files:
            if fname.endswith(".sql"):
                fpath = os.path.join(root, fname)
                changes = replace_in_file(fpath, replacements)
                if changes:
                    total_files += 1
                    total_changes += changes

    logger.info(f"[DONE] Applied {total_changes} replacements across {total_files} files.")


if __name__ == "__main__":
    import sys
    if len(sys.argv) < 2:
        print("Usage: python replace_strings_in_repo.py <path_to_translated_sql_repo>")
        sys.exit(1)
    replace_in_repo(sys.argv[1])

"""Locate the SQLite database, unpacking the gzipped copy on first use.

GitHub rejects files over 100 MB and pcards.db is 103 MB, so the repo stores data/pcards.db.gz
(about 22 MB). The first call unpacks it next to itself; later calls reuse the unpacked file.
"""
import gzip
import shutil
from pathlib import Path

DATA = Path(__file__).parent / "data"
DB = DATA / "pcards.db"
GZ = DATA / "pcards.db.gz"


def get_db_path() -> Path:
    if not DB.exists():
        if not GZ.exists():
            raise FileNotFoundError("Neither data/pcards.db nor data/pcards.db.gz was found.")
        tmp = DB.with_suffix(".tmp")
        with gzip.open(GZ, "rb") as src, open(tmp, "wb") as dst:
            shutil.copyfileobj(src, dst)
        tmp.replace(DB)
    return DB

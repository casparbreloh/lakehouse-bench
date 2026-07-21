import json
from pathlib import Path
Path('/out').mkdir(parents=True, exist_ok=True)
Path('/out/result.json').write_text(json.dumps({"status":"success","workload":"smoke","measurements":[{"name":"container-contract","status":"success","duration_ms":0,"result_checksum":"smoke"}]}))

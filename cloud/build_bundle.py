"""Package an allowlisted runnable snapshot. No credentials, .git or old results."""
import hashlib
from pathlib import Path
import tarfile

root=Path(__file__).resolve().parents[1]
output=root/'results/cloud_deploy';output.mkdir(parents=True,exist_ok=True)
archive=output/'orange-source.tar.gz'
paths=['Project_Orange.jl','Project.toml','Manifest.toml','setA','scripts','cloud','warm_starts','test/fixtures/orange_subject_toy']
with tarfile.open(archive,'w:gz') as bundle:
    for name in paths:
        path=root/name
        files=[path] if path.is_file() else sorted(path.rglob('*'))
        for item in files:
            if not item.is_file() or '__pycache__' in item.parts:continue
            bundle.add(item,arcname=str(item.relative_to(root)),recursive=False)
digest=hashlib.sha256(archive.read_bytes()).hexdigest()
(archive.parent/(archive.name+'.sha256')).write_text(digest+'  '+archive.name+'\n')
print(archive)
print('bytes',archive.stat().st_size,'sha256',digest)

"""Build an Azure source ZIP from this repository, without local data or secrets."""
import argparse
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--include-browser', action='store_true', help='Include the optional practice page')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    backend = root / 'backend'
    files = [(backend / name, name) for name in
             ('function_app.py', 'web_app.py', 'host.json', 'requirements.txt')]
    files += [(path, path.relative_to(backend).as_posix()) for path in sorted((backend / 'app').rglob('*.py'))
              if '__pycache__' not in path.parts]
    if args.include_browser:
        files += [(path, path.relative_to(root).as_posix()) for path in sorted((root / 'browser' / 'public').rglob('*'))
                  if path.is_file() and path.suffix in {'.html', '.css', '.mjs'}]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(args.output, 'w', ZIP_DEFLATED) as archive:
        for path, name in files:
            archive.write(path, name)
    print(f'Packaged {len(files)} files into {args.output}')


if __name__ == '__main__':
    main()

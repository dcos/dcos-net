#!/opt/mesosphere/bin/python

import io
import os
import sys
import json
import errno
import socket
import hashlib
import logging
import requests
import subprocess
import urllib.parse


class BadSHA512Sum(Exception):
    pass


class Controller():
    def __init__(self, metadata):
        self.block_size = 1048576  # 1MB
        self.metadata = metadata

    def sync(self, data_dir):
        filename = '/'.join([data_dir] + self.metadata['path'])
        if self._is_removed():
            return self._unlink(filename)
        if self.metadata.get('type') != 'http':
            logging.error('Unknown type (%s): %s',
                          self.metadata.get('type'), filename)
            return
        if self._is_leader():
            logging.info('Skip local file: %s', filename)
            return
        try:
            if os.path.isfile(filename):
                logging.info('Checking: %s', filename)
                self._check(filename)
            else:
                logging.info('Downloading: %s', filename)
                self._download(filename)
        except BadSHA512Sum:
            logging.info('Removing a file: %s', filename)
            try:
                os.unlink(filename)
            except OSError:
                pass
            self._download(filename)

    def _download(self, filename):
        dirname = os.path.dirname(filename)
        os.makedirs(dirname, exist_ok=True)

        r = requests.get(self.metadata['url'], stream=True)
        r.raise_for_status()

        sha512 = hashlib.sha512()
        fd = io.FileIO(filename, 'x')
        while True:
            data = r.raw.read(self.block_size)
            if not data:
                break
            sha512.update(data)
            fd.write(data)
        self._check_hashsum(sha512.hexdigest())
        fd.flush()
        os.fsync(fd.fileno())
        fd.close()
        logging.info('Saved: %s', filename)
        if self.metadata.get('install'):
            self._install(filename)

    def _check(self, filename):
        fd = io.FileIO(filename, 'r')
        sha512 = hashlib.sha512()
        while True:
            data = fd.read(self.block_size)
            if not data:
                break
            sha512.update(data)
        self._check_hashsum(sha512.hexdigest())
        logging.info('Checked: %s', filename)

    def _check_hashsum(self, sha512):
        if sha512 != self.metadata['sha512']:
            logging.error('Bad sha512 hashsum: %s', sha512)
            raise BadSHA512Sum()

    def _is_removed(self):
        return 'flags' in self.metadata and 'delete' in self.metadata['flags']

    def _unlink(self, filename):
        try:
            os.unlink(filename)
            logging.info('Removed: %s', filename)
        except OSError as e:
            if e.errno != errno.ENOENT:
                raise

    def _is_leader(self):
        result = \
            subprocess.run(
                ["/opt/mesosphere/bin/detect_ip"],
                stdout=subprocess.PIPE)
        if result.returncode != 0:
            return False
        ip = result.stdout.strip()
        hostname = urllib.parse.urlparse(self.metadata['url']).hostname
        return ip == socket.gethostbyname(hostname).encode()

    def _install(self, filename):
        result = subprocess.run(["/opt/mesosphere/bin/dcos-sfs-installer"])
        if result.returncode != 0:
            logging.error("Installer error: %d", result.returncode)


def main():
    if len(sys.argv) != 3:
        print('Usage: dcos-sfs-downloader.py HTTP_BASE_URL DIR', file=sys.stderr)
        sys.exit(1)
    base = sys.argv[1]
    data_dir = sys.argv[2]
    logging.basicConfig(
        stream=sys.stdout, level=logging.DEBUG,
        format='%(asctime)s [%(levelname)s] %(message)s',
        datefmt='')
    r = requests.get(base + '/sfs/v1/stream', stream=True)
    for line in r.iter_lines():
        meta = json.loads(line.decode())
        c = Controller(meta)
        c.sync(data_dir)


if __name__ == "__main__":
    main()

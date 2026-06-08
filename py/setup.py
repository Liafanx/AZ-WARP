"""
Setup для warper_api — Python API для WARPER (AZ-WARP).

Установка:
    pip install -e /root/warper/py
    pip install git+https://github.com/Liafanx/AZ-WARP.git#subdirectory=py
"""

import os
from setuptools import setup, find_packages

# Версия из файла WARPER
version = "0.0.0"
version_file = "/root/warper/version"
if os.path.exists(version_file):
    try:
        with open(version_file, "r") as f:
            version = f.read().strip() or version
    except OSError:
        pass

# Fallback — из локального version рядом с setup.py
if version == "0.0.0":
    local_version = os.path.join(os.path.dirname(__file__), "..", "version")
    if os.path.exists(local_version):
        try:
            with open(local_version, "r") as f:
                version = f.read().strip() or version
        except OSError:
            pass

setup(
    name="warper-api",
    version=version,
    description="Python API для управления WARPER (AZ-WARP)",
    long_description="Локальный Python-интерфейс для управления WARPER — "
                     "точечной маршрутизации доменов и IP через WARP/Slave/WG "
                     "на сервере с AntiZapret VPN.",
    author="Liafanx",
    url="https://github.com/Liafanx/AZ-WARP",
    license="MIT",
    packages=find_packages(),
    python_requires=">=3.9",
    install_requires=[],
    classifiers=[
        "Development Status :: 4 - Beta",
        "Intended Audience :: System Administrators",
        "License :: OSI Approved :: MIT License",
        "Operating System :: POSIX :: Linux",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
        "Programming Language :: Python :: 3.12",
        "Topic :: System :: Networking",
    ],
)

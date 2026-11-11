"""Shared setup: imports the Python core (windows/autozhuyin/core) and its data."""
import os
import sys
import types

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WIN = os.path.join(ROOT, "windows")
DATA = os.path.join(WIN, "autozhuyin", "data")
RESOURCES = os.path.join(ROOT, "Resources")
WEIGHTS_PATH = os.path.join(RESOURCES, "classifier-weights.json")

sys.path.insert(0, WIN)

from autozhuyin.core import bopomofo, features  # noqa: E402
from autozhuyin.core.classifier import LITERAL, ZHUYIN, Classifier  # noqa: E402
from autozhuyin.core.english import EnglishModel  # noqa: E402
from autozhuyin.core.lexicon import Lexicon  # noqa: E402

core = types.SimpleNamespace(bopomofo=bopomofo, features=features, Classifier=Classifier,
                             ZHUYIN=ZHUYIN, LITERAL=LITERAL)


def load_models():
    if not os.path.exists(os.path.join(DATA, "english-dict.txt")):
        sys.exit("Run windows/tools/build_data.py first.")
    lexicon = Lexicon.from_file(os.path.join(DATA, "lexicon.txt"))
    english = EnglishModel.from_files(os.path.join(DATA, "english-common.txt"),
                                      os.path.join(DATA, "english-dict.txt"),
                                      os.path.join(DATA, "english-bigram.json"))
    return lexicon, english

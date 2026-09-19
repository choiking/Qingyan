#!/usr/bin/env python3
"""Review candidate dictionary entries before they ship.

The upstream Ice dictionaries carry about 1.9 million entries, and a revision
bump adds thousands at a time. Mechanical problems (unknown syllable, reading
length that cannot match the word) are decided here in code. The judgments code
cannot make -- is this reading right for this word, is this a word at all, is it
worth offering as a default candidate -- go to a TypeSafe System One model, one
request per entry, and come back as typed answers with probabilities. Policy
thresholds below turn those answers into keep / flag / drop.

Nothing here runs on a user's machine or touches the shipped app: it runs when
update-dictionary.py pins a new revision, and writes a report you read plus an
exclusion list build.sh can subtract.

    # what changed since the pinned revision, mechanical checks only
    python3 Scripts/review-dictionary.py --old Vendor/rime-ice/cn_dicts \
        --new /path/to/new/cn_dicts --offline

    # same diff, with model judgments (needs TYPESAFE_API_KEY)
    python3 Scripts/review-dictionary.py --old ... --new ... --limit 400

    # calibrate the questions against entries already shipping
    python3 Scripts/review-dictionary.py --sample 50

The report and the answer cache land in Vendor/ (ignored). The exclusion list
lands in Resources/Rime/ and is meant to be committed: it is the record of what
this project chose not to ship, and why. build.sh copies only *.yaml out of
that directory, so the list itself never reaches the app bundle.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
import random
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DICTS = ROOT / "Vendor" / "rime-ice" / "cn_dicts"
CACHE_PATH = ROOT / "Vendor" / "dictionary-review-cache.json"
ENDPOINT = "https://api.typesafe.ai/v1/systemone"
MODEL = "jev-latest"

# Bump when a question's wording changes: cached answers key off this, so old
# answers to a different question are never reused.
QUESTION_VERSION = "1"

# What each upstream file is for. Sent as state because "this came from the
# proper-noun-heavy extension table" legitimately changes how an entry reads.
SOURCE_ROLE = {
    "8105": "通用规范汉字表 single characters",
    "41448": "extended single-character table, includes rare characters",
    "base": "core multi-character vocabulary",
    "ext": "extension table: three characters and up, proper nouns, names, titles",
    "tencent": "Tencent word-vector vocabulary, large and noisy",
    "others": "miscellaneous, mostly alternate readings",
}

HAN = re.compile(r"[㐀-䶿一-鿿豈-﫿]|[\U00020000-\U0003ffff]")


# --------------------------------------------------------------------------
# Reading dictionaries
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class Entry:
    word: str
    reading: str
    weight: int
    source: str

    @property
    def key(self) -> str:
        return f"{self.word}\t{self.reading}"


def parse_columns(header: str) -> list[str]:
    """Read the dictionary's `columns:` declaration.

    Rime defaults to text/code/weight, but tencent.dict.yaml declares
    text/weight and ships no readings at all -- Rime derives those from the
    single-character tables at build time. Assuming the default here silently
    reads every Tencent weight as if it were a pinyin reading.
    """
    columns, inside = [], False
    for line in header.splitlines():
        if line.startswith("#"):
            continue
        if line.startswith("columns:"):
            inside = True
            continue
        if inside:
            stripped = line.strip()
            if stripped.startswith("- "):
                columns.append(stripped[2:].strip())
                continue
            if stripped:
                break
    return columns or ["text", "code", "weight"]


def load_dict(path: Path) -> list[Entry]:
    """Parse one Rime .dict.yaml into entries, honouring its column layout."""
    text = path.read_text(encoding="utf-8-sig")
    if "\n...\n" not in text:
        raise ValueError(f"{path.name}: no YAML document terminator")
    header, body = text.split("\n...\n", 1)
    columns = parse_columns(header)
    source = path.name.removesuffix(".dict.yaml")
    entries = []
    for line in body.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        fields = dict(zip(columns, parts))
        word = fields.get("text", "").strip()
        if not word:
            continue
        reading = fields.get("code", "").strip()
        raw_weight = fields.get("weight", "").strip()
        weight = int(raw_weight) if raw_weight.isdigit() else 0
        entries.append(Entry(word, reading, weight, source))
    return entries


def load_tree(directory: Path) -> list[Entry]:
    files = sorted(directory.glob("*.dict.yaml"))
    if not files:
        raise SystemExit(f"No .dict.yaml files in {directory}")
    return [e for f in files for e in load_dict(f)]


def syllable_inventory(entries: list[Entry]) -> set[str]:
    """Valid pinyin syllables, derived from the single-character tables rather
    than hardcoded, so the inventory tracks whatever upstream ships."""
    return {
        e.reading for e in entries
        if e.source in ("8105", "41448")
        and e.reading and " " not in e.reading and e.reading.isascii()
    }


# --------------------------------------------------------------------------
# Mechanical checks -- rules, so they stay in code
# --------------------------------------------------------------------------

@dataclass
class Candidate:
    entry: Entry
    notes: list[str] = field(default_factory=list)
    suspicion: int = 0
    answers: dict | None = None
    verdict: str = "keep"
    reasons: list[str] = field(default_factory=list)


def han_chars(word: str) -> list[str]:
    return [c for c in word if HAN.match(c)]


def mechanical_check(entry: Entry, inventory: set[str]) -> tuple[list[str], int]:
    notes, suspicion = [], 0
    syllables = entry.reading.split()
    chars = han_chars(entry.word)

    if entry.reading:
        unknown = [s for s in syllables if s not in inventory]
        if unknown:
            notes.append(f"unknown syllable: {' '.join(unknown[:4])}")
            suspicion += 3

        if len(chars) == len(entry.word) and len(chars) != len(syllables):
            notes.append(f"{len(chars)} chars vs {len(syllables)} syllables")
            suspicion += 3
    else:
        # Rime derives the reading from the character tables. Nothing to check,
        # and nothing to ask the model about either.
        notes.append("no reading in source; Rime auto-annotates")

    non_han = [c for c in entry.word if not HAN.match(c)]
    if non_han:
        notes.append("non-Han characters: " + "".join(sorted(set(non_han))[:6]))
        suspicion += 1

    rare = [c for c in chars if unicodedata.category(c) == "Lo" and ord(c) > 0x9FA5]
    if rare:
        notes.append("rare/extension-block characters: " + "".join(rare[:4]))
        suspicion += 1

    if len(chars) >= 8:
        notes.append(f"unusually long: {len(chars)} characters")
        suspicion += 1

    if entry.weight <= 1 and entry.source == "base":
        notes.append("lowest weight in the core table")
        suspicion += 1

    return notes, suspicion


# --------------------------------------------------------------------------
# The judgments -- one request per entry, four independent questions
# --------------------------------------------------------------------------

def build_questions(has_reading: bool) -> dict:
    """The four judgments. Entries from tencent.dict.yaml carry no reading, so
    the reading question is left out for them rather than asked about a blank."""
    questions = {
        # Upstream's own ext table says its readings were annotated "通过朴素的
        # 脚本和勤劳的双手", so wrong 多音字 readings are the expected failure.
        "reading_matches": {
            "type": "noul",
            "instructions": {
                "question": "Is `reading` the pinyin a competent Mandarin speaker "
                            "would use when reading `word` aloud in its ordinary sense?",
                "note": "Readings are toneless, space-separated, one syllable per "
                        "character. Judge the syllables only, never the missing tones.",
            },
            "criteria": {
                "true": {
                    "meaning": "The reading is how this word is actually pronounced.",
                    "includes": "A heteronym read correctly for this particular word, "
                                "such as 银行 as `yin hang` rather than `yin xing`.",
                },
                "false": {
                    "meaning": "At least one syllable is wrong for this word.",
                    "includes": "A heteronym given its other reading, a syllable "
                                "belonging to a visually similar character, or a "
                                "reading copied from a different word.",
                },
            },
        },
        "entry_kind": {
            "type": "choice",
            "instructions": "What kind of entry is `word`? Judge the word itself, "
                            "not how common it is.",
            "criteria": {
                "general_word": "Ordinary vocabulary a general writer uses: nouns, "
                                "verbs, adjectives, set phrases, chengyu.",
                "proper_noun": "A specific name: person, place, company, product, "
                               "work of fiction, or a character in one.",
                "net_slang": "Internet or youth slang, memes, community jargon. "
                             "Includes recent coinages like 显眼包 or 情绪价值.",
                "technical_term": "Vocabulary specific to one profession or field: "
                                  "medicine, law, engineering, finance.",
                "dialect_or_classical": "Regional or non-Mandarin usage, or wording "
                                        "that survives only in classical text.",
                "fragment_or_junk": "Not a lexical unit: an arbitrary substring, two "
                                    "words run together, an OCR or encoding artifact, "
                                    "or a string with no meaning as written.",
            },
        },
        "typing_value": {
            "type": "score",
            "instructions": "How much would having `word` as a ready-made candidate "
                            "help someone typing Chinese on a general-purpose input "
                            "method? Rate the benefit of the entry existing, not "
                            "whether the reading attached to it is correct.",
            "criteria": [
                "Actively harmful: it would surface ahead of what people meant to "
                "type, because it is junk or a fragment that collides with a common "
                "reading.",
                "Dead weight: nobody outside a narrow specialty would ever type it, "
                "and it costs a candidate slot.",
                "Occasionally useful: a real word, typed rarely, worth having when "
                "someone needs it.",
                "Regularly useful: a word an ordinary writer types across a month of "
                "normal writing.",
                "Everyday vocabulary: typed constantly; its absence would be felt "
                "immediately.",
            ],
        },
        "unsafe_default": {
            "type": "noul",
            "instructions": "Would offering `word` as an automatic candidate be a "
                            "problem in itself, appearing unprompted while someone "
                            "types in a work chat or a document?",
            "criteria": {
                "true": "A slur, sexually explicit wording, or graphic abuse -- the "
                        "kind of thing whose unprompted appearance would be a bug "
                        "report.",
                "false": "Ordinary vocabulary. Words that merely describe crime, "
                         "illness, politics, or death are ordinary and belong here.",
            },
        },
    }
    if not has_reading:
        del questions["reading_matches"]
    return questions


def build_state(candidate: Candidate, siblings: dict[str, set[str]]) -> dict:
    entry = candidate.entry
    state = {
        "word": entry.word,
        "source_table": SOURCE_ROLE.get(entry.source, entry.source),
        "upstream_weight": entry.weight,
    }
    if entry.reading:
        state["reading"] = entry.reading
    others = sorted(siblings.get(entry.word, set()) - {entry.reading})
    if others:
        # A heteronym with several readings shipped is different from a word with
        # exactly one: say so rather than making the model assume.
        state["other_readings_shipped_for_this_word"] = others
    return state


# --------------------------------------------------------------------------
# Transport -- stdlib only, matching update-dictionary.py's zero-dependency style
# --------------------------------------------------------------------------

class TypeSafeError(RuntimeError):
    pass


def ask(state: dict, questions: dict, api_key: str, attempts: int = 5) -> dict:
    payload = json.dumps(
        {"state": state, "model": MODEL, "questions": questions}
    ).encode()
    request = urllib.request.Request(
        ENDPOINT,
        data=payload,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as error:
            # 429 and 529 are documented as retryable; 401 and 422 never are.
            if error.code not in (429, 529) or attempt == attempts - 1:
                detail = error.read().decode(errors="replace")[:400]
                raise TypeSafeError(f"HTTP {error.code}: {detail}") from error
        except (urllib.error.URLError, TimeoutError) as error:
            if attempt == attempts - 1:
                raise TypeSafeError(str(error)) from error
        time.sleep(min(2 ** attempt, 16) + random.random())
    raise TypeSafeError("retries exhausted")


def cache_key(entry: Entry) -> str:
    raw = f"{QUESTION_VERSION}\t{entry.key}\t{entry.source}"
    return hashlib.sha256(raw.encode()).hexdigest()[:24]


def load_cache() -> dict:
    if CACHE_PATH.exists():
        try:
            return json.loads(CACHE_PATH.read_text())
        except json.JSONDecodeError:
            pass
    return {}


def save_cache(cache: dict) -> None:
    CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    pending = CACHE_PATH.with_suffix(".json.pending")
    pending.write_text(json.dumps(cache, ensure_ascii=False, indent=0))
    pending.replace(CACHE_PATH)


# --------------------------------------------------------------------------
# Policy -- thresholds live here so they change without re-running inference
# --------------------------------------------------------------------------

def apply_policy(candidate: Candidate) -> None:
    """Turn typed answers into keep / flag / drop.

    These thresholds are a starting point, not measured truth. Run --sample
    against entries already shipping, read the report, and move them.
    """
    answers = candidate.answers
    if answers is None:
        candidate.verdict = "flag" if candidate.suspicion >= 3 else "keep"
        if candidate.suspicion >= 3:
            candidate.reasons.append("mechanical checks only; no model judgment")
        return

    kind = answers["entry_kind"]
    junk = kind["probabilities"].get("fragment_or_junk", 0.0)
    value = answers["typing_value"]["score"]
    value_confidence = answers["typing_value"]["confidence"]
    unsafe = answers["unsafe_default"]["noul"]

    drop, flag = [], []

    # Only present when the source shipped a reading to judge.
    if "reading_matches" in answers:
        reading = answers["reading_matches"]["noul"]
        if reading < 0.15:
            drop.append(f"reading looks wrong ({reading:.2f})")
        elif reading < 0.55:
            flag.append(f"reading uncertain ({reading:.2f})")

    if junk > 0.60:
        drop.append(f"not a lexical unit ({junk:.2f})")
    elif junk > 0.30:
        flag.append(f"may not be a word ({junk:.2f})")

    # Harm is only worth acting on when the entry earns nothing: a common word
    # someone actually types stays, whatever it denotes.
    if unsafe > 0.70 and value < 2.5:
        drop.append(f"unsafe as a default candidate ({unsafe:.2f}), low value")
    elif unsafe > 0.70:
        flag.append(f"unsafe as a default candidate ({unsafe:.2f}) but commonly typed")

    if value < 0.6 and value_confidence > 0.60:
        drop.append(f"would displace what people meant to type ({value:.2f})")

    # An uncertain Score is the model saying the levels don't place this entry.
    # That is a review signal, not a reason to act.
    if value_confidence < 0.35 and not drop:
        flag.append(f"value judgment unreliable (confidence {value_confidence:.2f})")

    if drop:
        candidate.verdict, candidate.reasons = "drop", drop + flag
    elif flag:
        candidate.verdict, candidate.reasons = "flag", flag
    else:
        candidate.verdict = "keep"


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------

def write_report(candidates: list[Candidate], path: Path, offline: bool) -> None:
    rows = ["\t".join((
        "verdict", "word", "reading", "source", "weight",
        "reading_ok", "kind", "value", "unsafe", "reasons", "mechanical",
    ))]
    order = {"drop": 0, "flag": 1, "keep": 2}
    for candidate in sorted(candidates, key=lambda c: (order[c.verdict], -c.suspicion)):
        answers, entry = candidate.answers, candidate.entry
        if answers:
            reading_ok = (f"{answers['reading_matches']['noul']:.2f}"
                          if "reading_matches" in answers else "n/a")
            kind = answers["entry_kind"]["choice"]
            value = f"{answers['typing_value']['score']:.2f}"
            unsafe = f"{answers['unsafe_default']['noul']:.2f}"
        else:
            reading_ok = kind = value = unsafe = "-"
        rows.append("\t".join((
            candidate.verdict, entry.word, entry.reading, entry.source,
            str(entry.weight), reading_ok, kind, value, unsafe,
            "; ".join(candidate.reasons) or "-",
            "; ".join(candidate.notes) or "-",
        )))
    path.write_text("\n".join(rows) + "\n", encoding="utf-8")


def write_exclusions(candidates: list[Candidate], path: Path) -> int:
    dropped = [c for c in candidates if c.verdict == "drop"]
    lines = [
        "# Entries this review dropped. Subtract in build.sh, or delete a line to",
        "# keep an entry. Regenerated by Scripts/review-dictionary.py.",
    ]
    lines += [f"{c.entry.word}\t{c.entry.reading}\t# {'; '.join(c.reasons)}"
              for c in dropped]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(dropped)


# --------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--old", type=Path, default=DEFAULT_DICTS,
                        help="currently pinned cn_dicts directory")
    parser.add_argument("--new", type=Path,
                        help="candidate cn_dicts directory; review what it adds")
    parser.add_argument("--sample", type=int, metavar="N",
                        help="instead of a diff, review N random shipping entries")
    parser.add_argument("--limit", type=int, default=300,
                        help="most entries to send to the model (default: 300)")
    parser.add_argument("--all", action="store_true",
                        help="review every added entry, not just suspicious ones")
    parser.add_argument("--offline", action="store_true",
                        help="mechanical checks only; no API key needed")
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--report", type=Path,
                        default=ROOT / "Vendor" / "dictionary-review.tsv")
    parser.add_argument("--exclusions", type=Path,
                        default=ROOT / "Resources" / "Rime" / "dictionary-exclude.txt")
    args = parser.parse_args()

    if not args.new and not args.sample:
        parser.error("pass --new DIR to review an update, or --sample N to calibrate")

    random.seed(args.seed)
    baseline = load_tree(args.old)
    inventory = syllable_inventory(baseline)
    print(f"Baseline: {len(baseline):,} entries, {len(inventory)} syllables", file=sys.stderr)

    if args.sample:
        # An explicit sample size is the instruction; don't second-guess it.
        args.limit = max(args.limit, args.sample)
        pool = random.sample(baseline, min(args.sample, len(baseline)))
        siblings_source = baseline
        print(f"Sampling {len(pool):,} shipping entries", file=sys.stderr)
    else:
        known = {e.key for e in baseline}
        incoming = load_tree(args.new)
        pool = [e for e in incoming if e.key not in known]
        siblings_source = incoming
        removed = known - {e.key for e in incoming}
        print(f"Candidate: {len(incoming):,} entries -- "
              f"{len(pool):,} added, {len(removed):,} removed", file=sys.stderr)

    siblings: dict[str, set[str]] = {}
    for entry in siblings_source:
        siblings.setdefault(entry.word, set()).add(entry.reading)

    candidates = []
    for entry in pool:
        notes, suspicion = mechanical_check(entry, inventory)
        candidates.append(Candidate(entry=entry, notes=notes, suspicion=suspicion))

    if args.sample or args.all:
        selected = candidates
    else:
        # Most of a diff is unremarkable. Send what the rules find odd, plus a
        # control sample, so the report says something about the rest.
        suspicious = [c for c in candidates if c.suspicion > 0]
        rest = [c for c in candidates if c.suspicion == 0]
        control = random.sample(rest, min(len(rest), max(0, args.limit - len(suspicious))))
        selected = suspicious + control
        print(f"{len(suspicious):,} flagged by rules, "
              f"{len(control):,} sampled as control", file=sys.stderr)

    selected.sort(key=lambda c: -c.suspicion)
    if len(selected) > args.limit:
        print(f"Limiting to {args.limit:,} of {len(selected):,} "
              f"(raise with --limit)", file=sys.stderr)
        selected = selected[:args.limit]

    if not args.offline:
        api_key = os.environ.get("TYPESAFE_API_KEY")
        if not api_key:
            print("TYPESAFE_API_KEY is not set. Create a key at "
                  "https://console.typesafe.ai/ and export it, or pass --offline "
                  "to run the mechanical checks alone.", file=sys.stderr)
            return 2

        cache = load_cache()
        pending = [c for c in selected if cache_key(c.entry) not in cache]
        for candidate in selected:
            cached = cache.get(cache_key(candidate.entry))
            if cached:
                candidate.answers = cached
        print(f"{len(selected) - len(pending):,} cached, "
              f"{len(pending):,} to ask", file=sys.stderr)

        failures = 0
        if pending:
            def run(candidate: Candidate):
                state = build_state(candidate, siblings)
                questions = build_questions(bool(candidate.entry.reading))
                return candidate, ask(state, questions, api_key)

            with concurrent.futures.ThreadPoolExecutor(args.workers) as pool_exec:
                futures = [pool_exec.submit(run, c) for c in pending]
                for done, future in enumerate(
                    concurrent.futures.as_completed(futures), start=1
                ):
                    try:
                        candidate, response = future.result()
                    except TypeSafeError as error:
                        failures += 1
                        if failures <= 3:
                            print(f"  request failed: {error}", file=sys.stderr)
                        continue
                    candidate.answers = response["answers"]
                    cache[cache_key(candidate.entry)] = response["answers"]
                    if done % 25 == 0 or done == len(futures):
                        print(f"  {done}/{len(futures)}", file=sys.stderr)
            save_cache(cache)
        if failures:
            print(f"{failures} request(s) failed; those entries were not judged",
                  file=sys.stderr)

    for candidate in selected:
        apply_policy(candidate)

    write_report(selected, args.report, args.offline)
    dropped = write_exclusions(selected, args.exclusions)
    counts = {v: sum(1 for c in selected if c.verdict == v)
              for v in ("drop", "flag", "keep")}
    print(f"\nReviewed {len(selected):,}: {counts['drop']} drop, "
          f"{counts['flag']} flag, {counts['keep']} keep", file=sys.stderr)
    print(f"Report:     {args.report.relative_to(ROOT)}", file=sys.stderr)
    print(f"Exclusions: {args.exclusions.relative_to(ROOT)} ({dropped} entries)",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

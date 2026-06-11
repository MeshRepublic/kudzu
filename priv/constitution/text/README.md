# Founding Canon Source Texts

All files in this directory are public-domain primary-source materials
used by the U.S. Constitutional Framework distillation. Sources:

- `constitution/constitution.txt` — Preamble + 7 Articles + 27 Amendments.
  Sources: National Archives transcripts —
  - Main body: <https://www.archives.gov/founding-docs/constitution-transcript>
  - Amendments I–X: <https://www.archives.gov/founding-docs/bill-of-rights-transcript>
  - Amendments XI–XXVII: <https://www.archives.gov/founding-docs/amendments-11-27>

- `federalist/federalist_NN.txt` — Federalist Paper #NN (NN zero-padded
  01–85). Source: Project Gutenberg eBook 1404 (compiled volume),
  <https://www.gutenberg.org/files/1404/1404-0.txt>, split on the
  per-paper `FEDERALIST No. N` header.

- `anti_federalist/{brutus,cato,federal_farmer,centinel}.txt` —
  Letters series in the public domain, one file per series, individual
  letters separated by a Roman-numeral header and `===` rule.
  Source: TeachingAmericanHistory.org transcriptions
  (`https://teachingamericanhistory.org/document/<slug>-<roman>/`).
  Counts: Brutus I–XV (15 letters), Cato I–VII (7 letters),
  Federal Farmer I–XVIII (18 letters), Centinel I–XVIII (18 letters).

**Citation policy:** corpus modules track paragraph offsets so the
Distiller can produce paragraph-level citations. Calibration set asserts
at paper level (per spec decision #13) to avoid brittle tests against
chunking changes.

**Excluded for v0 (per decision #2):** Yates/Lansing convention notes
(reportage genre, contested 1821 editorial history). Corpus is additive;
re-running distillation after adding sources is safe and idempotent.

**Updating sources:** never edit the text files in place. If a
transcription has an error, replace the entire file with a corrected
copy from the same primary-source publisher. The corpus is reproducible
from canonical sources; in-place edits break that property.

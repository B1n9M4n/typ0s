# Training data (kept on your Mac only)

`data/` is git-ignored. The GitHub Typo Corpus licence follows each source repository, so it's for local training, not for publishing.

How the files in `data/` were made:

1. `prep_ghtypo.py`: from the GitHub Typo Corpus (Hugging Face mirror `chirunder/github_typo_corrections`, 353k real typo fixes), keep English sentences where 1–2 words changed by a small slip. Writes `nonword_*` (misspelled words) and `realword_*` (real word typed as another real word), split 50/50 into train and test.
2. `slip_filter.py`: keeps only real-word changes that are keyboard slips (neighbour key, swapped keys, doubled or dropped key), not grammar. Writes `realslip_*`.
3. `my_slips.py`: makes slips in the style of your own freewriting (extra key bled in, swapped keys, space in the wrong place, neighbour key, missed key) on clean sentences. Writes `myslips_*`.

Train only on `*_train.tsv`. Score on `*_test.tsv`, which the training never sees.

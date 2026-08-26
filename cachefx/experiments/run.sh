#!/usr/bin/env bash

echo "Running all CacheFX experiments."

bash experiments/16kb_experiments.sh
bash experiments/32kb_experiments.sh
bash experiments/64kb_experiments.sh
bash experiments/128kb_experiments.sh
bash experiments/256kb_experiments.sh

echo "Done running all CacheFX experiments."

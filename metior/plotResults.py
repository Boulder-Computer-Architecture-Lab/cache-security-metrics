import pandas as pd
import matplotlib.pyplot as plt
import sys
import os


p = sys.argv[1]
df = pd.read_pickle(p)
# Get base name
p = os.path.basename(p)

print(df)

fig = df.pivot(index='Ratio', columns='NumPrimes', values='Leakage').plot(figsize=(5,3))
plt.xlabel("Number of Lines Primed")
plt.ylabel("Maximal Leakage (bits)")
plt.legend(title="Number of Primes")
plt.tight_layout()
plt.show()

os.makedirs("fig", exist_ok=True)
fout = f"fig/{p}.pdf"
print(fout)
plt.savefig(fout)

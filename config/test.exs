import Config

# Force the binary Nx backend in the test environment so EXLA NIFs are not
# required to run the suite. EXLA still loads (the dependency is compiled in)
# but the actual Nx default operates on plain binaries, which is fast enough
# for the unit tests and keeps the suite portable to dev machines without
# CUDA / NCCL installed.
config :nx, :default_backend, Nx.BinaryBackend
config :nx, :default_defn_options, []

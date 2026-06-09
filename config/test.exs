import Config

# Force the binary Nx backend in the test environment so EXLA NIFs are not
# required to run the suite. EXLA still loads (the dependency is compiled in)
# but the actual Nx default operates on plain binaries, which is fast enough
# for the unit tests and keeps the suite portable to dev machines without
# CUDA / NCCL installed.
config :nx, :default_backend, Nx.BinaryBackend
config :nx, :default_defn_options, []

# Isolated data root for tests — never touches production DETS / Mnesia.
# Unique per `mix test` invocation so back-to-back runs do not collide
# on left-over DETS files. The directory is created here so module-level
# `init/1` callbacks can open DETS files inside it immediately.
test_root = Path.join(System.tmp_dir!(), "kudzu-test-#{System.system_time(:millisecond)}")
File.mkdir_p!(test_root)
config :kudzu, :data_root, test_root

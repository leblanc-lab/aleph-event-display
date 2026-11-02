// Dump the detector-level record of selected events from ALEPH EDM4HEP (podio) files to JSON, for
// edisplay.jl, which normally runs this itself. Plain ROOT (podio splits every collection into basic leaves).
//
//   root -l -b -q 'edm4hep_dump.C("events.tsv", "outdir")'
//
// events.tsv: name  file  entry  (one line per event, no header; entry is 0-based). One JSON per event, keyed by leaf
// name, every value an array (one entry per collection element). Leaves are read with
// TTreeReaderArray of the leaf's own type; fixed-size array members (covariances) are skipped.
#include <TFile.h>
#include <TTree.h>
#include <TLeaf.h>
#include <TTreeReader.h>
#include <TTreeReaderArray.h>
#include <cstdio>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace {
const char* kKeep[] = {"EventHeader.", "BeamSpot.", "Tracks.", "_Tracks_trackStates.", "_Tracks_subdetectorHitNumbers",
  "ElectromagneticClusters.", "HadronicClusters.", "_ElectromagneticClusters_subdetectorEnergies",
  "_HadronicClusters_subdetectorEnergies", "RecoParticles.", "_RecoParticles_tracks.", "_RecoParticles_clusters.",
  "ParticleID.", "_ParticleID_particle.", "V0Vertices.", "_V0Vertices_particles.", "V0Particles.",
  "_V0Particles_tracks.", "Vertices.", "Jets.", "dEdxPads.", "_dEdxPads_track.", "dEdxWires.", "_dEdxWires_track."};

bool wanted(const std::string& n) {
  if (n.find(".values") != std::string::npos) return false;   // fixed-size arrays inside structs
  for (const char* k : kKeep) if (n.rfind(k, 0) == 0) return true;
  return false;
}

struct Col {
  std::string name;
  virtual ~Col() = default;
  virtual void write(FILE* f) = 0;
};
template <typename T> struct TCol : Col {
  TTreeReaderArray<T> a;
  TCol(TTreeReader& r, const std::string& n) : a(r, n.c_str()) { name = n; }
  void write(FILE* f) override {
    fprintf(f, "\"%s\":[", name.c_str());
    for (size_t i = 0; i < a.GetSize(); ++i) fprintf(f, i ? ",%.9g" : "%.9g", double(a[i]));
    fprintf(f, "]");
  }
};
}

void edm4hep_dump(const char* list, const char* outdir) {
  std::ifstream in(list); std::string line;
  while (std::getline(in, line)) {
    std::istringstream ls(line); std::string name, path; Long64_t entry;
    if (!(ls >> name >> path >> entry)) continue;
    TFile f(path.c_str());
    TTree* t = f.IsZombie() ? nullptr : (TTree*)f.Get("events");
    if (!t) { printf("ERROR %s: no events tree in %s\n", name.c_str(), path.c_str()); continue; }
    TTreeReader r(t);
    std::vector<std::unique_ptr<Col>> cols;
    for (TObject* o : *t->GetListOfLeaves()) {
      TLeaf* l = (TLeaf*)o; std::string n = l->GetName(), ty = l->GetTypeName();
      if (!wanted(n)) continue;
      if (ty == "Float_t" || ty == "vector<float>") cols.emplace_back(new TCol<float>(r, n));
      else if (ty == "Double_t") cols.emplace_back(new TCol<double>(r, n));
      else if (ty == "Int_t" || ty == "vector<int>") cols.emplace_back(new TCol<int>(r, n));
      else if (ty == "UInt_t") cols.emplace_back(new TCol<unsigned int>(r, n));
      else if (ty == "Short_t") cols.emplace_back(new TCol<short>(r, n));
      else if (ty == "ULong64_t") cols.emplace_back(new TCol<ULong64_t>(r, n));
      else if (ty == "ULong_t") cols.emplace_back(new TCol<ULong_t>(r, n));
      else if (ty == "Long64_t") cols.emplace_back(new TCol<Long64_t>(r, n));
      else printf("skip %s (%s)\n", n.c_str(), ty.c_str());
    }
    if (r.SetEntry(entry) != TTreeReader::kEntryValid) { printf("ERROR %s entry %lld\n", name.c_str(), entry); continue; }
    std::string out = std::string(outdir) + "/" + name + ".json";
    FILE* fo = fopen(out.c_str(), "w");
    fprintf(fo, "{\"name\":\"%s\",\"file\":\"%s\",\"entry\":%lld,", name.c_str(), path.c_str(), entry);
    for (size_t i = 0; i < cols.size(); ++i) { if (i) fprintf(fo, ","); cols[i]->write(fo); }
    fprintf(fo, "}\n"); fclose(fo);
    printf("wrote %s (%zu leaves)\n", out.c_str(), cols.size());
    // Collection IDs -> names, for the relation leaves (`*.collectionID`).
    if (TTree* m = (TTree*)f.Get("podio_metadata")) {
      std::string idt = std::string(outdir) + "/" + name + "_idtable.txt";
      FILE* fi = fopen(idt.c_str(), "w");
      for (TObject* o : *m->GetListOfLeaves()) fprintf(fi, "%s %s\n", o->GetName(), ((TLeaf*)o)->GetTypeName());
      fclose(fi);
    }
  }
}

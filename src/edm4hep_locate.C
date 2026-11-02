// Find the tree entries of run:event pairs in ALEPH EDM4HEP files, for edisplay.jl --event.
//
//   root -l -b -q 'edm4hep_locate.C("files.txt", "29614:2192,29638:3392")'
//
// files.txt: one path per line. Prints "FOUND run event path entry" per match, reading only the
// EventHeader branch, and stops as soon as every requested event is found.
#include <TFile.h>
#include <TTree.h>
#include <TLeaf.h>
#include <cstdio>
#include <fstream>
#include <set>
#include <sstream>
#include <string>
#include <utility>

void edm4hep_locate(const char* list, const char* wanted) {
  std::set<std::pair<unsigned long long, unsigned long long>> want;
  std::stringstream ss(wanted); std::string item;
  while (std::getline(ss, item, ',')) {
    auto c = item.find(':');
    want.insert({std::stoull(item.substr(0, c)), std::stoull(item.substr(c + 1))});
  }
  std::ifstream in(list); std::string path;
  while (!want.empty() && std::getline(in, path)) {
    if (path.empty()) continue;
    TFile f(path.c_str());
    TTree* t = f.IsZombie() ? nullptr : (TTree*)f.Get("events");
    if (!t) { printf("ERROR no events tree in %s\n", path.c_str()); continue; }
    t->SetBranchStatus("*", 0);
    t->SetBranchStatus("EventHeader*", 1);
    TLeaf* lr = t->GetLeaf("EventHeader.runNumber"); TLeaf* le = t->GetLeaf("EventHeader.eventNumber");
    if (!lr || !le) { printf("ERROR no EventHeader in %s\n", path.c_str()); continue; }
    for (Long64_t i = 0; i < t->GetEntries() && !want.empty(); ++i) {
      t->GetEntry(i);
      auto key = std::make_pair((unsigned long long)lr->GetValue(0), (unsigned long long)le->GetValue(0));
      if (want.erase(key)) printf("FOUND %llu %llu %s %lld\n", key.first, key.second, path.c_str(), i);
    }
  }
}

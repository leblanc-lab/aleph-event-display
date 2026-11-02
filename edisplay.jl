#!/usr/bin/env julia
# Detector-level ALEPH event displays from EDM4HEP files: an end view (x–y, DALI-style fish-eye), a
# side view (z–ρ) and a 3D perspective view with the ALEPH outlines, tracks drawn as helices from their
# fitted track states, ECAL/HCAL energy, V⁰ decay vertices and the sphericity axis; optionally a
# vertex-region zoom and a θ–φ map; and one interactive 3D page per event (three.js, works offline).
#
#   julia --project=. edisplay.jl --file F.root --entry 22624
#   julia --project=. edisplay.jl --file DIR_OR_FILES... --event 29614:2192,29638:3392
#   julia --project=. edisplay.jl --events list.tsv          # file  entry  [label], tab-separated
#
# ROOT (edm4hep_dump.C) first writes each event's record to JSON in OUT/json; the displays are drawn
# from those JSON files, so a rerun with other views or themes does not read the ROOT files again.
using ArgParse, JSON, CairoMakie, LinearAlgebra, Printf, Statistics, TOML

s = ArgParseSettings(description="ALEPH event displays from EDM4HEP files: end, side and 3D views, and interactive 3D pages.")
@add_arg_table! s begin
    "--file", "-f"; nargs='+'; default=String[]; help="EDM4HEP ROOT file(s); a directory stands for its *.root files."
    "--entry", "-e"; default=""; help="Comma-separated tree entries (0-based) of the single --file."
    "--event"; default=""; help="Comma-separated RUN:EVENT pairs, searched for in the --file inputs."
    "--events"; default=""; help="Event list, one per line, tab-separated: file  entry  [label]."
    "--label"; default=""; help="Text at the top right of every display (an --events label takes precedence)."
    "--out", "-o"; default="edisplay_out"; help="Output directory."
    "--views"; default="composite,end,side,3d"; help="Static views: composite (end | side | 3D), end, side, 3d, vertex, map, compact."
    "--themes"; default="light,dark"; help="Comma-separated themes: light, dark, dali."
    "--hits"; action=:store_true; help="Mark where tracks cross the VDET/ITC/TPC layers (always on for dali)."
    "--formats"; default="png,pdf"; help="Comma-separated file formats of the static views."
    "--no-static"; action=:store_true; help="Only write the interactive pages."
    "--no-html"; action=:store_true; help="Only write the static views."
    "--config"; default=joinpath(@__DIR__, "config", "default.toml"); help="Settings TOML (selections, conventions, header)."
    "--root"; default=""; help="ROOT executable (default: root on PATH, then \$ROOTSYS/bin/root)."
    "--redump"; action=:store_true; help="Read the ROOT files again even if OUT/json has the event."
    "--calibrate"; action=:store_true; help="Derive the track-state conventions from these events' V⁰s instead of the config."
end
a = parse_args(s)
const CFG = TOML.parsefile(a["config"])
const OUT = a["out"]; mkpath(OUT)
const JSONDIR = joinpath(OUT, "json"); mkpath(JSONDIR)
const B = Float64(CFG["display"]["bfield"])
const EXPERIMENT = CFG["display"]["experiment"]
const FORMATS = split(a["formats"], ','; keepempty=false)
set_theme!(Theme(fontsize=15))

# ── events: which file and entry ─────────────────────────────────────────────
function rootexe()
    isempty(a["root"]) || return a["root"]
    r = Sys.which("root"); r === nothing || return r
    haskey(ENV, "ROOTSYS") && isfile(joinpath(ENV["ROOTSYS"], "bin", "root")) && return joinpath(ENV["ROOTSYS"], "bin", "root")
    error("ROOT not found: put root on PATH, set ROOTSYS, or pass --root")
end
runroot(macro, args...) = read(pipeline(`$(rootexe()) -l -b -q $(joinpath(@__DIR__, "src", macro) * "(" * join(("\"$x\"" for x in args), ",") * ")")`; stdin=devnull), String)
inputs() = [f for p in a["file"] for f in (isdir(p) ? sort(filter(endswith(".root"), readdir(p; join=true))) : [p])]
key(file, entry) = replace(basename(file), r"\.root$" => "") * "_$entry"

events = NamedTuple{(:key, :file, :entry, :label),Tuple{String,String,Int,String}}[]
if !isempty(a["events"])
    for l in eachline(a["events"])
        (isempty(strip(l)) || startswith(l, '#')) && continue
        c = occursin('\t', l) ? split(l, '\t') : split(l)
        push!(events, (key=key(c[1], c[2]), file=String(c[1]), entry=parse(Int, c[2]), label=length(c) >= 3 ? String(strip(c[3])) : a["label"]))
    end
elseif !isempty(a["entry"])
    length(inputs()) == 1 || error("--entry needs exactly one --file")
    f = only(inputs())
    for e in split(a["entry"], ','); push!(events, (key=key(f, e), file=f, entry=parse(Int, e), label=a["label"])); end
elseif !isempty(a["event"])
    files = inputs(); isempty(files) && error("--event needs --file inputs to search")
    list = joinpath(JSONDIR, "locate_files.txt"); write(list, join(files, "\n") * "\n")
    @info "searching $(length(files)) file(s) for $(a["event"])"
    found = Dict{String,Tuple{String,Int}}()
    for l in eachline(IOBuffer(runroot("edm4hep_locate.C", list, a["event"])))
        c = split(l); length(c) == 5 && c[1] == "FOUND" && (found["$(c[2]):$(c[3])"] = (c[4], parse(Int, c[5])))
        startswith(l, "ERROR") && @warn l
    end
    for w in split(a["event"], ',')
        haskey(found, w) || (@warn "event $w not found in the --file inputs"; continue)
        f, e = found[w]; push!(events, (key=key(f, e), file=f, entry=e, label=a["label"]))
    end
else
    error("say which events to draw: --file with --entry or --event, or --events")
end
isempty(events) && error("no events to draw")

todo = [ev for ev in events if a["redump"] || !isfile(joinpath(JSONDIR, ev.key * ".json"))]
if !isempty(todo)
    list = joinpath(JSONDIR, "dump.tsv"); write(list, join(("$(ev.key)\t$(ev.file)\t$(ev.entry)" for ev in todo), "\n") * "\n")
    for l in eachline(IOBuffer(runroot("edm4hep_dump.C", list, JSONDIR))); startswith(l, "ERROR") && @warn l; end
end
filter!(ev -> isfile(joinpath(JSONDIR, ev.key * ".json")) || (@warn "no record for $(ev.file) entry $(ev.entry)"; false), events)
isempty(events) && error("no event records were written")

col(d, k) = Float64.(get(d, k, Float64[]))
span(d, coll, rel, i) = (b = col(d, "$coll.$(rel)_begin"); e = col(d, "$coll.$(rel)_end"); Int(b[i])+1:Int(e[i]))
data = [JSON.parsefile(joinpath(JSONDIR, ev.key * ".json")) for ev in events]

# ── tracks, V⁰s and the track-state conventions ──────────────────────────────
"""Tracks of an event with their linked reco particle (or nothing)."""
function tracks(d)
    nt = length(col(d, "Tracks.chi2")); rp_of = Dict{Int,Int}()
    nrp = length(col(d, "RecoParticles.energy"))
    idx = col(d, "_RecoParticles_tracks.index")
    for i in 1:nrp, k in span(d, "RecoParticles", "tracks", i)
        rp_of[Int(idx[k])+1] = i
    end
    ts = (d0=col(d, "_Tracks_trackStates.D0"), phi=col(d, "_Tracks_trackStates.phi"), om=col(d, "_Tracks_trackStates.omega"),
          z0=col(d, "_Tracks_trackStates.Z0"), tl=col(d, "_Tracks_trackStates.tanLambda"),
          xr=col(d, "_Tracks_trackStates.referencePoint.x"), yr=col(d, "_Tracks_trackStates.referencePoint.y"), zr=col(d, "_Tracks_trackStates.referencePoint.z"))
    hits = col(d, "_Tracks_subdetectorHitNumbers")
    dedx(coll) = Dict(Int(i) + 1 => (v, e) for (i, v, e) in zip(col(d, "_$(coll)_track.index"), col(d, "$coll.dQdx.value"), col(d, "$coll.dQdx.error")) if v > -900)
    dpad, dwire = dedx("dEdxPads"), dedx("dEdxWires")
    chi2, ndf = col(d, "Tracks.chi2"), col(d, "Tracks.ndf")
    out = NamedTuple[]
    for k in 1:nt
        r = span(d, "Tracks", "trackStates", k); isempty(r) && continue
        j = first(r)                                      # first state: at the interaction point
        h = span(d, "Tracks", "subdetectorHitNumbers", k)
        hv = length(h) >= 3 ? Int.(hits[h]) : [0, 0, 0]
        rp = get(rp_of, k, 0)
        p = rp == 0 ? nothing : [col(d, "RecoParticles.momentum.x")[rp], col(d, "RecoParticles.momentum.y")[rp], col(d, "RecoParticles.momentum.z")[rp]]
        push!(out, (k=k, d0=ts.d0[j], phi=ts.phi[j], om=ts.om[j], z0=ts.z0[j], tl=ts.tl[j],
                    ref=(ts.xr[j], ts.yr[j], ts.zr[j]), hits=hv, rp=rp, p=p,
                    q=rp == 0 ? 0.0 : col(d, "RecoParticles.charge")[rp], chi2=chi2[k], ndf=ndf[k],
                    dedxpad=get(dpad, k, (NaN, NaN)), dedxwire=get(dwire, k, (NaN, NaN))))
    end
    out
end
alltracks = [tracks(d) for d in data]

"""Helix of a track: PCA at `sd`·d0 along (−sin φ0, cos φ0) from the reference point, centre on the
side given by `sb`·q. Returns a function s ↦ (x, y, z) in cm, s the transverse path length."""
function trackhelix(t; sd, sb, lscale, qsign)
    R = abs(1 / t.om) / lscale
    φ = t.phi; ref = t.ref
    P0 = (ref[1] - sd * t.d0 * sin(φ), ref[2] + sd * t.d0 * cos(φ))
    κ = sb * qsign * sign(t.om)                      # +1: clockwise seen from +z
    C = (P0[1] + κ * R * sin(φ), P0[2] - κ * R * cos(φ))
    v = (P0[1] - C[1], P0[2] - C[2])
    h = function (s)
        α = -κ * s / R
        (C[1] + v[1] * cos(α) - v[2] * sin(α), C[2] + v[1] * sin(α) + v[2] * cos(α), ref[3] + t.z0 + s * t.tl)
    end
    return h, R
end

const V0CUT = CFG["v0"]
"""Displaced V⁰ vertices (cm) with the raw indices of their two linked objects."""
function v0s(d)
    x, y, z, c = col(d, "V0Vertices.position.x"), col(d, "V0Vertices.position.y"), col(d, "V0Vertices.position.z"), col(d, "V0Vertices.chi2")
    idx = col(d, "_V0Vertices_particles.index")
    [(pos=(x[i], y[i], z[i]), raw=[Int(idx[k]) for k in span(d, "V0Vertices", "particles", i)])
     for i in eachindex(x) if c[i] < V0CUT["chi2_max"] && hypot(x[i], y[i]) > V0CUT["rxy_min"]]
end
allv0 = [v0s(d) for d in data]
rptracks(d, i) = [Int(col(d, "_RecoParticles_tracks.index")[k]) + 1 for k in span(d, "RecoParticles", "tracks", i)]
daughters(d, v, interp) = interp == :track ? [r + 1 for r in v.raw if r + 1 <= length(col(d, "Tracks.chi2"))] :
                          [k for r in v.raw if r + 1 <= length(col(d, "RecoParticles.energy")) for k in rptracks(d, r + 1)]

# Curvature units and charge sign from tracks with a reco particle: R = pT / (0.3 B) in m vs |1/ω|.
ratios = [abs(1 / t.om) / (100 * norm(t.p[1:2]) / (0.3B)) for T in alltracks for t in T if t.p !== nothing && t.om != 0]
qsigns = [sign(t.om) * t.q for T in alltracks for t in T if t.q != 0]
function calibrate()
    lscale = 10.0^round(log10(median(ratios)))   # length units of 1/ω per cm (cm 1, mm 10, m 0.01)
    qsign = sign(median(qsigns))
    # d0 sign, curvature side and link target: the daughter tracks of a V⁰ must pass through its vertex.
    function circledist(t, v; sd, sb)
        h, R = trackhelix(t; sd, sb, lscale, qsign); best = Inf
        for s in range(0, min(π * R, 200); length=2000)
            x, y, _ = h(s); best = min(best, hypot(x - v.pos[1], y - v.pos[2]))
        end
        best
    end
    cands = [(sd, sb, ip) for sd in (1.0, -1.0), sb in (1.0, -1.0), ip in (:track, :rp)]
    scores = [median(vcat([[circledist(T[findfirst(t -> t.k == k, T)], v; sd, sb) for k in daughters(d, v, ip) if any(t -> t.k == k, T)]
                           for (d, T, V) in zip(data, alltracks, allv0) for v in V]..., [Inf])) for (sd, sb, ip) in cands]
    for (c, sc) in zip(vec(cands), vec(scores)); @info @sprintf("calibration: d0 sign %+g, curvature side %+g, links to %-5s → median vertex miss %.2f cm", c[1], c[2], c[3], sc); end
    all(isinf, scores) && error("--calibrate needs events with V⁰ candidates")
    sd, sb, link = cands[argmin(scores)]
    @info "calibrated conventions" omega_per_cm=lscale omega_sign=qsign d0_sign=sd curvature_side=sb v0_links=(link == :rp ? "particles" : "tracks")
    (lscale, qsign, sd, sb, link)
end
const CONV = CFG["conventions"]
const LSCALE, QSIGN, SD, SB, LINK = a["calibrate"] ? calibrate() :
    (Float64(CONV["omega_per_cm"]), Float64(CONV["omega_sign"]), Float64(CONV["d0_sign"]), Float64(CONV["curvature_side"]),
     CONV["v0_links"] == "tracks" ? :track : :rp)
# Files with other conventions would draw tracks that miss their clusters; say so instead.
isempty(ratios) || abs(log10(median(ratios) / LSCALE)) < 0.1 ||
    @warn @sprintf("|1/ω| / R(pT) = %.3g, but the config says %g: tracks will have the wrong curvature (try --calibrate)", median(ratios), LSCALE)
isempty(qsigns) || sign(median(qsigns)) == QSIGN ||
    @warn "sign(ω) × charge disagrees with the config's omega_sign: tracks will bend the wrong way (try --calibrate)"
helix(t) = trackhelix(t; sd=SD, sb=SB, lscale=LSCALE, qsign=QSIGN)

# ── drawing ──────────────────────────────────────────────────────────────────
# Three themes. "dali" follows the ALEPH event display DALI (deep blue page, black TPC, red
# calorimeter modules with white edges, yellow tracks and energy histograms), modernized; "light"
# and "dark" use the same layout with a bold palette.
const THEMES = Dict(
    "light" => (bg="#FFFFFF", fg="#16161A", muted="#8C8C96", line="#8E95A3", tpc=("#9AA0AA", .07), coil=("#9AA0AA", .10),
                ecal=("#E3175F", .10), hcal=("#E89A00", .10), modline=.55, track="#3F2FD6", other="#A6A6B0",
                v0="#0095C8", em="#E3175F", hc="#E89A00", axis="#16161A", padrows=false),
    "dark"  => (bg="#07080C", fg="#ECECF2", muted="#80869A", line="#59607A", tpc=("#59607A", .14), coil=("#59607A", .18),
                ecal=("#FF4D9B", .14), hcal=("#FFB52E", .12), modline=.55, track="#B3A6FF", other="#5D6378",
                v0="#3FD2F2", em="#FF4D9B", hc="#FFB52E", axis="#ECECF2", padrows=false),
    "dali"  => (bg="#1B44C4", fg="#FFFFFF", muted="#C7D3FF", line="#FFFFFF", tpc=("#05060B", 1.), coil=("#1B44C4", 1.),
                ecal=("#C8102E", 1.), hcal=("#C8102E", 1.), modline=.95, track="#FFD60A", other="#6FC3FF",
                v0="#5CF2E8", em="#FFD60A", hc="#FFD60A", axis="#FFFFFF", padrows=true))

# ALEPH geometry (cm), from the detector paper, Nucl. Instr. Meth. A294 (1990) 121:
# beam pipe Ø 156 mm; ITC walls r = 12.8–28.5, length 2 m; TPC r = 31–180, length 4.7 m;
# ECAL barrel: 12 modules, r = 184.7–225.4, length 4.7 m, rotated −32.7 mrad (−1.875°) with
# respect to HCAL; ECAL end caps r = 54–234.8, 56.25 cm thick; coil cryostat Ø 4.96–5.84 m, 7.0 m long;
# HCAL barrel: dodecagon 7.24 m long, 9.37 m across flats, 1.2 m of iron in 23 layers (inner face
# ≈ 297 cm); HCAL end caps 1.18 m thick, 8.7 m across flats, central hole Ø 90 cm; LCAL r = 10–52,
# z = 266.8–302.2; muon chambers: two double layers outside the iron, 50 cm apart.
# End-cap z positions are not tabulated in the paper; they are placed against the barrel ends.
const G = (pipe=7.8, itc=(12.8, 28.5, 100.), tpc=(31., 180., 235.),
           ecal=(184.7, 225.4, 235.), ecap=(54., 234.8, 240., 296.25), ecalrot=-1.875,
           coil=(248., 292., 350.), hcal=(297., 468.5, 362.), hcap=(45., 435., 362., 480.),
           lcal=(10., 52., 266.8, 302.2), mu=(478., 528.))

# DALI's fish-eye projection: a radius r is drawn at f(r) = r / (1 + r/R₀), so the tracker fills
# most of the picture and the calorimeters become thin rings (R₀ = 180 cm: the TPC outer wall is
# drawn at 90, the HCAL outer face at 129). Applied to the end view (transverse radius) only: in the
# side view it would bend the horizontal detector boundaries, so the side, 3D and vertex views are linear.
const FISH = 180.0
fish(r) = r / (1 + r / FISH)
fishpt(x, y) = (r = hypot(x, y); r == 0 ? Point2f(0, 0) : Point2f(x * fish(r) / r, y * fish(r) / r))
fishpt(p::Makie.VecTypes{2}) = fishpt(p[1], p[2])
"""Subdivide a closed or open polyline so straight edges bend correctly under the fish-eye."""
densify(pts; n=24) = vcat([[pts[k] + (pts[k+1] - pts[k]) * (j / n) for j in 0:n-1] for k in 1:length(pts)-1]..., [pts[end]])
fpoly!(ax, pts; proj=fishpt, kw...) = poly!(ax, proj.(densify(Point2f.(pts))); kw...)
flines!(ax, pts; proj=fishpt, kw...) = lines!(ax, proj.(densify(Point2f.(pts))); kw...)
"""Half-width (cm) of the linear side view: the muon chambers and the HCAL end caps just fit."""
const SIDEHALF = 545.0

ngon(r, n=12; φ0=π/n) = [Point2f(r * cos(φ0 + 2π * k / n), r * sin(φ0 + 2π * k / n)) for k in 0:n]
ringpts(r) = [Point2f(r * cos(t), r * sin(t)) for t in range(0, 2π; length=241)]
"""Distance from the axis to a flat-topped dodecagon of apothem `a`, rotated by `rot` degrees, at azimuth φ."""
facedist(a, φ; rot=0.) = (c = deg2rad(rot); a / cos(mod(φ - c + π / 12, π / 6) - π / 12))
"""Twelve trapezoidal modules between apothems a0 and a1 (flat top, rotated by `rot` degrees)."""
function modules!(ax, a0, a1, fill, line; rot=0.)
    for k in 0:11
        c = deg2rad(rot) + k * π / 6
        q = [Point2f((a / cos(π / 12)) * cos(c + s * π / 12), (a / cos(π / 12)) * sin(c + s * π / 12)) for (a, s) in ((a0, -1), (a1, -1), (a1, 1), (a0, 1))]
        push!(q, q[1]); fpoly!(ax, q; color=fill, strokecolor=line, strokewidth=1.0)
    end
end
annulus!(ax, r0, r1, fill, line) = poly!(ax, Makie.Polygon(fishpt.(ringpts(r1)), [reverse(fishpt.(ringpts(r0)))]); color=fill, strokecolor=line, strokewidth=.9)
"""ALEPH end view (x–y)."""
function endview_detector!(ax, th; zoom=false)
    L(a=th.modline) = (th.line, a)
    flines!(ax, ngon(G.mu[2] / cos(π / 12)); color=L(.35), linewidth=.8)                      # muon chambers
    flines!(ax, ngon(G.mu[1] / cos(π / 12)); color=L(.35), linewidth=.8)
    modules!(ax, G.hcal[1], G.hcal[2], th.hcal, L())                                         # HCAL barrel
    annulus!(ax, G.coil[1], G.coil[2], th.coil, L())                                         # coil
    modules!(ax, G.ecal[1], G.ecal[2], th.ecal, L(); rot=G.ecalrot)                           # ECAL barrel
    poly!(ax, fishpt.(ringpts(G.tpc[2])); color=th.tpc, strokecolor=L(), strokewidth=.9)     # TPC
    poly!(ax, fishpt.(ringpts(G.tpc[1])); color=th.bg, strokecolor=L(), strokewidth=.8)
    annulus!(ax, G.itc[1], G.itc[2], th.tpc, L())                                            # ITC
    lines!(ax, fishpt.(ringpts(G.pipe)); color=L(.8), linewidth=.7)                          # beam pipe
    for r in (6.3, 10.8); lines!(ax, fishpt.(ringpts(r)); color=L(.5), linewidth=.5); end   # VDET
end
"""ALEPH side view (z–ρ), mirrored about the beam; linear scale."""
function sideview_detector!(ax, th)
    L(a=th.modline) = (th.line, a)
    rect(z0, z1, r0, r1, f) = for s in (1, -1)
        y0, y1 = s > 0 ? (r0, r1) : (-r1, -r0)
        poly!(ax, [Point2f(z0, y0), Point2f(z1, y0), Point2f(z1, y1), Point2f(z0, y1)]; color=f, strokecolor=L(), strokewidth=.9)
    end
    for s in (1, -1)                                                                           # muon chambers
        for m in G.mu; lines!(ax, [Point2f(-G.hcap[4], s * m), Point2f(G.hcap[4], s * m)]; color=L(.35), linewidth=.8); end
        for z in (G.hcap[4] + 12, G.hcap[4] + 52); lines!(ax, [Point2f(s * z, -G.mu[2]), Point2f(s * z, G.mu[2])]; color=L(.35), linewidth=.8); end
    end
    rect(-G.hcal[3], G.hcal[3], G.hcal[1], G.hcal[2], th.hcal)                                  # HCAL barrel
    rect(G.hcap[3], G.hcap[4], G.hcap[1], G.hcap[2], th.hcal); rect(-G.hcap[4], -G.hcap[3], G.hcap[1], G.hcap[2], th.hcal)
    rect(-G.coil[3], G.coil[3], G.coil[1], G.coil[2], th.coil)                                  # coil
    rect(-G.ecal[3], G.ecal[3], G.ecal[1], G.ecal[2], th.ecal)                                  # ECAL barrel + end caps
    rect(G.ecap[3], G.ecap[4], G.ecap[1], G.ecap[2], th.ecal); rect(-G.ecap[4], -G.ecap[3], G.ecap[1], G.ecap[2], th.ecal)
    rect(G.lcal[3], G.lcal[4], G.lcal[1], G.lcal[2], th.ecal); rect(-G.lcal[4], -G.lcal[3], G.lcal[1], G.lcal[2], th.ecal)
    rect(-G.tpc[3], G.tpc[3], G.tpc[1], G.tpc[2], th.tpc)                                       # TPC, ITC
    rect(-G.itc[3], G.itc[3], G.itc[1], G.itc[2], th.tpc)
    lines!(ax, [Point2f(-SIDEHALF, 0), Point2f(SIDEHALF, 0)]; color=L(.8), linewidth=.6)
end
"""Wireframe of the TPC cylinder and the ECAL dodecagon in 3D; the beam runs along the horizontal axis."""
function detector3d!(ax, th)
    P(x, y, z) = Point3f(z, x, y)                         # plot axes: beam, x, y (vertical)
    C = th.em; T = th.line
    for zz in (-G.tpc[3], G.tpc[3])
        lines!(ax, [P(G.tpc[2] * cos(a), G.tpc[2] * sin(a), zz) for a in range(0, 2π; length=121)]; color=(T, .6), linewidth=.8)
    end
    for a in range(0, 2π; length=13)[1:end-1]
        lines!(ax, [P(G.tpc[2] * cos(a), G.tpc[2] * sin(a), -G.tpc[3]), P(G.tpc[2] * cos(a), G.tpc[2] * sin(a), G.tpc[3])]; color=(T, .25), linewidth=.6)
    end
    rc = G.ecal[2] / cos(π / 12); rot = deg2rad(G.ecalrot)
    corner(k) = (rc * cos(rot + π / 12 + k * π / 6), rc * sin(rot + π / 12 + k * π / 6))
    for zz in (-G.ecal[3], G.ecal[3])
        lines!(ax, [P(corner(k)..., zz) for k in 0:12]; color=(C, .6), linewidth=.8)
    end
    for k in 0:11
        lines!(ax, [P(corner(k)..., -G.ecal[3]), P(corner(k)..., G.ecal[3])]; color=(C, .35), linewidth=.6)
    end
    lines!(ax, [P(0, 0, -330), P(0, 0, 330)]; color=(T, .9), linewidth=.8)
end
"""Radii (cm) of the 21 TPC pad rows: 9 in the inner K sectors (38–91 cm), 12 in the outer W/M sectors (100–170 cm)."""
const PADROWS = vcat(range(39.9, 87.6; length=9), range(103.0, 172.3; length=12))
const ITCLAYERS = collect(range(16.0, 26.0; length=8))   # eight drift-cell layers, r = 16–26 cm
const VDETLAYERS = [6.3, 10.8]                          # two silicon layers

"""Where a fitted track crosses the VDET, ITC and TPC layers, in the order it crosses them.
The files store only the number of hits per detector, not their positions, so these points are
the fitted trajectory at the layer radii, at most as many per detector as hits were recorded."""
function layercrossings(pts, hits)
    out = Tuple{Float64,Float64,Float64,Int}[]          # x, y, z, detector (1 VDET, 2 ITC, 3 TPC)
    for (det, radii) in enumerate((VDETLAYERS, ITCLAYERS, PADROWS))
        n = 0
        for k in 2:length(pts)
            r0, r1 = hypot(pts[k-1][1], pts[k-1][2]), hypot(pts[k][1], pts[k][2])
            r1 > r0 || continue                          # outgoing half of the helix only
            for R in radii
                r0 <= R < r1 || continue
                n < hits[det] || break
                w = (R - r0) / (r1 - r0); q = pts[k-1] .+ w .* (pts[k] .- pts[k-1])
                push!(out, (q..., det)); n += 1
            end
        end
    end
    out
end
function scalebar!(ax, th, x, y, len, label)
    lines!(ax, [Point2f(x, y), Point2f(x + len, y)]; color=th.fg, linewidth=2)
    text!(ax, x + len / 2, y; text=label, align=(:center, :bottom), offset=(0, 5), fontsize=20, color=th.fg)
end
blankaxis(pos, th; kw...) = (ax = Axis(pos; aspect=DataAspect(), backgroundcolor=th.bg, kw...); hidedecorations!(ax); hidespines!(ax); ax)
function themedaxis(pos, th; kw...)
    Axis(pos; backgroundcolor=th.bg, xgridvisible=false, ygridvisible=false, leftspinecolor=th.muted, rightspinecolor=th.muted,
         topspinecolor=th.muted, bottomspinecolor=th.muted, xtickcolor=th.muted, ytickcolor=th.muted, xminortickcolor=th.muted,
         yminortickcolor=th.muted, xticklabelcolor=th.fg, yticklabelcolor=th.fg, xlabelcolor=th.fg, ylabelcolor=th.fg, kw...)
end
function savefig(fig, name)
    for ext in FORMATS
        ext == "png" ? save(joinpath(OUT, "$name.png"), fig; px_per_unit=2) : save(joinpath(OUT, "$name.$ext"), fig)
    end
end

const TRK, NEU = CFG["tracks"], CFG["neutrals"]
passes(t) = (t.p !== nothing && norm(t.p[1:2]) > TRK["pt_min"] && abs(t.p[3] / norm(t.p)) < TRK["abs_costheta_max"] &&
             t.hits[3] >= TRK["tpc_hits_min"] && abs(t.d0) < TRK["abs_d0_max"] && abs(t.z0) < TRK["abs_z0_max"])

"""Keep a V⁰ candidate if the daughters' invariant mass is in the K⁰S (ππ) or Λ (pπ either way)
window and the summed momentum points back to the beam spot. The mass field of the V⁰ particles is
empty in these files, so the mass is recomputed from the two linked reco particles. Returns nothing
or the V⁰ with its species."""
function goodv0(d, v)
    LINK == :rp || return merge(v, (kind="V⁰",))
    rp = [r + 1 for r in v.raw if r + 1 <= length(col(d, "RecoParticles.energy"))]
    length(rp) == 2 || return nothing
    P = [[col(d, "RecoParticles.momentum.x")[i], col(d, "RecoParticles.momentum.y")[i], col(d, "RecoParticles.momentum.z")[i]] for i in rp]
    mass(m1, m2) = (e = sqrt(sum(abs2, P[1]) + m1^2) + sqrt(sum(abs2, P[2]) + m2^2); sqrt(max(e^2 - sum(abs2, P[1] .+ P[2]), 0)))
    mπ, mp = 0.13957, 0.93827
    bs = isempty(col(d, "BeamSpot.position.x")) ? [0., 0., 0.] : [col(d, "BeamSpot.position.x")[1], col(d, "BeamSpot.position.y")[1], col(d, "BeamSpot.position.z")[1]]
    r = collect(v.pos) .- bs; ptot = P[1] .+ P[2]
    dot(r, ptot) / (norm(r) * norm(ptot)) > V0CUT["pointing_cos_min"] || return nothing
    abs(mass(mπ, mπ) - .4976) < V0CUT["k0s_window"] && return merge(v, (kind="K⁰S",))
    (abs(mass(mp, mπ) - 1.1157) < V0CUT["lambda_window"] || abs(mass(mπ, mp) - 1.1157) < V0CUT["lambda_window"]) && return merge(v, (kind="Λ",))
    nothing
end

const VIEWS = split(a["views"], ','; keepempty=false)
const THEMELIST = split(a["themes"], ','; keepempty=false)
for v in VIEWS; v in ("composite", "end", "side", "3d", "vertex", "map", "compact") || error("unknown view $v"); end
for t in THEMELIST; haskey(THEMES, t) || error("unknown theme $t"); end

"""Draw one event; returns its output name."""
function draw_event(d, T, V, entry, label)
    V = filter(!isnothing, [goodv0(d, v) for v in V])
    run = Int(col(d, "EventHeader.runNumber")[1])
    evn = isempty(col(d, "EventHeader.eventNumber")) ? entry : Int(col(d, "EventHeader.eventNumber")[1])
    name = "run$(run)_event$(evn)"
    px, py, pz = col(d, "RecoParticles.momentum.x"), col(d, "RecoParticles.momentum.y"), col(d, "RecoParticles.momentum.z")
    E = col(d, "RecoParticles.energy"); q = col(d, "RecoParticles.charge")
    M = zeros(3, 3); for i in eachindex(E); v = [px[i], py[i], pz[i]]; M .+= v * v'; end
    ax3 = eigen(Symmetric(M)).vectors[:, 3]
    # Clusters carry no position in these files; their direction is (iTheta, iPhi) in radians. Place
    # each on the inner surface of its calorimeter (barrel radius, or the endcap plane beyond it).
    function onsurface(coll, rin, zin)
        θ, φ, En = col(d, "$coll.iTheta"), col(d, "$coll.iPhi"), col(d, "$coll.energy")
        u = [(sin(t) * cos(p), sin(t) * sin(p), cos(t)) for (t, p) in zip(θ, φ)]
        λ = [min(rin / max(hypot(v[1], v[2]), 1e-9), zin / max(abs(v[3]), 1e-9)) for v in u]
        (E=En, u=u, x=[l * v[1] for (l, v) in zip(λ, u)], y=[l * v[2] for (l, v) in zip(λ, u)], z=[l * v[3] for (l, v) in zip(λ, u)])
    end
    em = onsurface("ElectromagneticClusters", G.ecal[1], G.ecap[3])
    hc = onsurface("HadronicClusters", G.hcal[1], G.hcap[3])
    v0daughters = Set(k for v in V for k in daughters(d, v, LINK))
    v0of = Dict(k => v for v in V for k in daughters(d, v, LINK))
    nfrag = count(t -> t.rp == 0, T)
    T = filter(t -> t.rp != 0, T)
    paths = map(T) do t
        h, R = helix(t); pts = NTuple{3,Float64}[]
        s0 = 0.0
        if haskey(v0of, t.k)                      # a V⁰ daughter starts where it passes its decay vertex
            vp = v0of[t.k].pos
            grid = range(0, min(π * R, 200); length=4000)
            s0 = grid[argmin([hypot(h(s)[1] - vp[1], h(s)[2] - vp[2]) for s in grid])]
        end
        for s in range(s0, s0 + π * R; length=600)
            p = h(s); (hypot(p[1], p[2]) > 180 || abs(p[3]) > 220) && break; push!(pts, p)
        end
        (t=t, pts=pts, good=passes(t), v0=t.k in v0daughters, hits=layercrossings(pts, t.hits))
    end
    ngood = count(p -> p.good, paths); nneu = count(i -> q[i] == 0, eachindex(q))
    order = sortperm(paths; by=p -> (p.good || p.v0, p.v0))  # other tracks underneath
    # ECAL clusters belonging to neutral particles that fail the neutral selection. Particle→cluster
    # links point only into the ECAL collection in these files; HCAL clusters carry no particle link.
    emunsel = Set{Int}()
    if length(unique(col(d, "_RecoParticles_clusters.collectionID"))) == 1
        cidx = col(d, "_RecoParticles_clusters.index")
        for i in eachindex(E)
            q[i] == 0 || continue
            pp = sqrt(px[i]^2 + py[i]^2 + pz[i]^2); ct = pp > 0 ? abs(pz[i] / pp) : 1.0
            (E[i] < NEU["energy_min"] || ct > NEU["abs_costheta_max"]) || continue
            for k in span(d, "RecoParticles", "clusters", i); push!(emunsel, Int(cidx[k]) + 1); end
        end
    end
    a["no-html"] || write_html(name, run, evn, label, paths, em, hc, V, ax3, ngood, nneu, sum(E), emunsel)
    @info "$name: $(length(T)) tracks ($ngood selected), $(length(V)) V⁰, $(length(em.E)) ECAL + $(length(hc.E)) HCAL clusters; $nfrag track fragments without a reco particle not drawn"
    a["no-static"] && return name
    for base in THEMELIST
        th = THEMES[base]
        showhits = a["hits"] || th.padrows
        tname = a["hits"] && !th.padrows ? "$(base)_hits" : base
        tc(p) = p.v0 ? th.v0 : p.good ? th.track : th.other
        tw(p) = p.good || p.v0 ? 1.9 : .9
        # Calorimeter energy as histograms: ECAL in 1.875° bins (two ECAL towers), HCAL in its 3.75°
        # towers, each bar rising from the outer face of its calorimeter, length logarithmic in energy.
        barlen(E, full) = full * clamp(log1p(E) / log1p(25.0), .06, 1.2)   # display units (fish-eye cm)
        function histo!(ax, c, a0, rot, full, col, binw)
            nb = round(Int, 360 / binw); h = zeros(nb)
            for i in eachindex(c.E)
                φ = mod(atan(c.y[i], c.x[i]), 2π); h[clamp(floor(Int, rad2deg(φ) / binw) + 1, 1, nb)] += c.E[i]
            end
            for b in findall(>(0), h)
                φ0, φ1 = deg2rad((b - 1) * binw), deg2rad(b * binw); φm = (φ0 + φ1) / 2
                r0 = fish(facedist(a0, φm; rot)); r1 = r0 + barlen(h[b], full)
                poly!(ax, Point2f[(r0 * cos(φ0), r0 * sin(φ0)), (r1 * cos(φ0), r1 * sin(φ0)), (r1 * cos(φ1), r1 * sin(φ1)), (r0 * cos(φ1), r0 * sin(φ1))];
                      color=col, strokecolor=(th.bg, .6), strokewidth=.4)
            end
        end
        function draw_end!(ax; zoom=false)
            endview_detector!(ax, th; zoom)
            if !zoom
                histo!(ax, em, G.ecal[2], G.ecalrot, 28.0, th.em, 1.875)   # from the ECAL outer face, as DALI
                histo!(ax, hc, G.hcal[2], 0.0, 40.0, th.hc, 3.75)          # from the HCAL outer face
            end
            for p in paths[order]
                length(p.pts) < 2 && continue
                xy = [zoom ? Point2f(x, y) : fishpt(x, y) for (x, y, _) in p.pts]
                hp = [zoom ? Point2f(h[1], h[2]) : fishpt(h[1], h[2]) for h in p.hits]
                if th.padrows && !zoom          # DALI: coordinates, with the fit faint behind them
                    p.good || p.v0 ? (lines!(ax, xy; color=(tc(p), .55), linewidth=.8); scatter!(ax, hp; color=tc(p), markersize=4.5, strokewidth=0)) :
                                     scatter!(ax, hp; color=tc(p), markersize=3.5, strokewidth=0)
                else
                    lines!(ax, xy; color=tc(p), linewidth=zoom ? 1.5tw(p) : tw(p))
                    showhits && !isempty(hp) && scatter!(ax, hp; color=tc(p), markersize=zoom ? 7 : 4.5, strokecolor=th.bg, strokewidth=.7)
                end
            end
            if !zoom
                a2 = normalize(ax3[1:2]) .* fish(1e4)
                lines!(ax, [Point2f(-a2...), Point2f(a2...)]; color=(th.axis, .5), linestyle=:dot, linewidth=1.2)
            end
            for v in V
                scatter!(ax, [zoom ? Point2f(v.pos[1], v.pos[2]) : fishpt(v.pos[1], v.pos[2])]; color=th.v0, marker=:diamond, markersize=zoom ? 16 : 10, strokecolor=th.bg, strokewidth=.8)
            end
            lim = zoom ? 40 : 172; limits!(ax, -lim, lim, -lim, lim)
            zoom && scalebar!(ax, th, 24, -36, 10, "10 cm")   # the fish-eye view has no single scale
        end
        function draw_side!(ax)
            sideview_detector!(ax, th)
            k = SIDEHALF / 172   # calorimeter bars: the end view's display units → cm of the linear view
            for (c, cc, full) in ((em, th.em, 22.0), (hc, th.hc, 34.0)), i in eachindex(c.E)
                u = c.u[i]; s = sign(c.y[i]) * hypot(u[1], u[2]); p0 = Point2f(c.z[i], sign(c.y[i]) * hypot(c.x[i], c.y[i]))
                d = Point2f(u[3], s); n = Point2f(-d[2], d[1]) * 2.5 * k
                p1 = p0 + k * barlen(c.E[i], full) * d
                poly!(ax, Point2f[p0 - n, p1 - n, p1 + n, p0 + n]; color=cc, strokewidth=0)
            end
            for p in paths[order]
                length(p.pts) < 2 && continue
                sgn = p.pts[end][2] >= 0 ? 1 : -1
                lines!(ax, [Point2f(z, sgn * hypot(x, y)) for (x, y, z) in p.pts]; color=tc(p), linewidth=tw(p))
                showhits && !isempty(p.hits) && scatter!(ax, [Point2f(h[3], sgn * hypot(h[1], h[2])) for h in p.hits]; color=tc(p),
                    markersize=4, strokecolor=th.bg, strokewidth=.6)
            end
            ρ = sign(ax3[2]) * norm(ax3[1:2]); sc = 1e4 / hypot(ax3[3], ρ)
            lines!(ax, [Point2f(-sc * ax3[3], -sc * ρ), Point2f(sc * ax3[3], sc * ρ)]; color=(th.axis, .5), linestyle=:dot, linewidth=1.2)
            limits!(ax, -SIDEHALF, SIDEHALF, -SIDEHALF, SIDEHALF)
        end
        function draw_3d!(ax)
            P(x, y, z) = Point3f(z, x, y)
            detector3d!(ax, th)
            for p in paths[order]
                length(p.pts) < 2 && continue
                lines!(ax, [P(x, y, z) for (x, y, z) in p.pts]; color=tc(p), linewidth=tw(p))
            end
            for (c, cc, dep, lw, rin, zin) in ((em, th.em, 40.0, 6, G.ecal[1], G.ecap[3]), (hc, th.hc, 45.0, 9, G.ecal[2] + 4, G.ecap[4] + 4)), i in eachindex(c.E)
                u = c.u[i]; λ = min(rin / max(hypot(u[1], u[2]), 1e-9), zin / max(abs(u[3]), 1e-9)); p0 = P((λ .* u)...)
                linesegments!(ax, Point3f[p0, Point3f(p0 + barlen(c.E[i], dep) * P(u[1], u[2], u[3]))]; color=cc, linewidth=lw)
            end
            for v in V; scatter!(ax, [P(v.pos...)]; color=th.v0, marker=:diamond, markersize=10); end
            lines!(ax, [P((-430 .* ax3)...), P((430 .* ax3)...)]; color=(th.axis, .55), linestyle=:dot, linewidth=1.2)
            limits!(ax, -300, 300, -275, 275, -275, 275)
        end
        function draw_map!(ax)
            θφ(x, y, z) = (rad2deg(mod(atan(y, x), 2π)), rad2deg(atan(hypot(x, y), z)))
            for (c, cc, lab) in ((hc, th.hc, "hadronic cluster"), (em, th.em, "electromagnetic cluster"))
                isempty(c.E) && continue
                scatter!(ax, [Point2f(θφ(c.x[i], c.y[i], c.z[i])...) for i in eachindex(c.E)]; color=(cc, .85), marker=:rect,
                         markersize=5 .+ 5 .* sqrt.(c.E), strokewidth=0, label=lab)
            end
            tr = [i for i in eachindex(q) if q[i] != 0]
            scatter!(ax, [Point2f(θφ(px[i], py[i], pz[i])...) for i in tr]; color=th.track, marker=:xcross,
                     markersize=6 .+ 3 .* sqrt.(E[tr]), label="track (momentum direction)")
            limits!(ax, 0, 360, 0, 180); ax.yreversed = true
            axislegend(ax; position=:rb, framevisible=false, backgroundcolor=(th.bg, .85), labelcolor=th.fg, labelsize=16, patchsize=(14, 14), rowgap=0)
        end
        legend_elems = [LineElement(color=th.track, linewidth=3), LineElement(color=th.other, linewidth=2),
                        LineElement(color=th.v0, linewidth=3), MarkerElement(color=th.v0, marker=:diamond, markersize=13),
                        LineElement(color=th.em, linewidth=8), LineElement(color=th.hc, linewidth=8),
                        LineElement(color=(th.axis, .6), linestyle=:dot, linewidth=2)]
        legend_labels = ["selected track", "other track", "V⁰ daughter", "V⁰ vertex", "ECAL energy", "HCAL energy", "sphericity axis"]
        if showhits
            push!(legend_elems, MarkerElement(color=th.track, marker=:circle, markersize=8, strokecolor=th.bg, strokewidth=.7))
            push!(legend_labels, "VDET/ITC/TPC layer crossings")
        end
        stats = @sprintf("%d selected tracks  ·  %d neutral objects  ·  %d V⁰  ·  %.1f GeV visible", ngood, nneu, length(V), sum(E))
        # Header: experiment and event on the left, the label large on the right; footer: one legend row and one stats line.
        function header!(f, cols; size=30, lsize=size + 4)
            Label(f[0, cols], EXPERIMENT * "    run $run · event $evn"; halign=:left, tellwidth=false, fontsize=size, color=th.fg, font=:bold)
            isempty(label) || Label(f[0, cols], label; halign=:right, tellwidth=false, fontsize=lsize, color=th.fg, font=:bold)
        end
        function footer!(f, cols; size=20)
            Legend(f[2, cols], legend_elems, legend_labels; orientation=:horizontal, tellwidth=false, tellheight=true, halign=:left,
                   labelsize=size, labelcolor=th.fg, framevisible=false, backgroundcolor=(th.bg, 0), patchsize=(34, 14), colgap=26)
            Label(f[2, cols], stats; halign=:right, tellwidth=false, fontsize=size, color=th.muted)
        end
        newaxis3(pos) = (ax = Axis3(pos; aspect=:data, perspectiveness=.4, azimuth=1.22π, elevation=.14π, backgroundcolor=th.bg,
                                    protrusions=0, viewmode=:fitzoom);
                         hidedecorations!(ax); ax.xspinesvisible = ax.yspinesvisible = ax.zspinesvisible = false;
                         ax.xgridvisible = ax.ygridvisible = ax.zgridvisible = false; ax)
        for view in VIEWS
            if view == "compact"
                # the three panels on a smaller canvas, so the text stays legible at a document's text width
                f = Figure(size=(1800, 760), backgroundcolor=th.bg, figure_padding=(14, 14, 8, 8))
                header!(f, 1:3; size=28)
                draw_end!(blankaxis(f[1, 1], th)); draw_side!(blankaxis(f[1, 2], th)); draw_3d!(newaxis3(f[1, 3]))
                Legend(f[2, 1:3], legend_elems, legend_labels; orientation=:horizontal, tellwidth=false, tellheight=true, halign=:center,
                       labelsize=24, labelcolor=th.fg, framevisible=false, backgroundcolor=(th.bg, 0), patchsize=(34, 14), colgap=26)
                colgap!(f.layout, 10); rowgap!(f.layout, 4)
                savefig(f, "$(name)_compact_$tname")
            elseif view == "composite"
                # three equal panels: end view, side view, 3D view
                f = Figure(size=(2700, 1080), backgroundcolor=th.bg, figure_padding=(26, 26, 14, 14))
                header!(f, 1:3)
                draw_end!(blankaxis(f[1, 1], th)); draw_side!(blankaxis(f[1, 2], th)); draw_3d!(newaxis3(f[1, 3]))
                footer!(f, 1:3)
                colgap!(f.layout, 18); rowgap!(f.layout, 8)
                savefig(f, "$(name)_composite_$tname")
            else
                sz = Dict("end" => (1150, 1250), "side" => (1150, 1250), "3d" => (1250, 1250), "vertex" => (1000, 1100), "map" => (1300, 820))[view]
                g = Figure(size=sz, backgroundcolor=th.bg, figure_padding=(20, 20, 12, 12))
                header!(g, 1; size=24, lsize=28)
                if view == "end"
                    draw_end!(blankaxis(g[1, 1], th))
                elseif view == "side"
                    draw_side!(blankaxis(g[1, 1], th))
                elseif view == "vertex"
                    draw_end!(blankaxis(g[1, 1], th); zoom=true)
                elseif view == "3d"
                    draw_3d!(newaxis3(g[1, 1]))
                else
                    ax = themedaxis(g[1, 1], th; xlabel="φ [°]", ylabel="θ [°]", xticks=0:90:360, yticks=0:45:180, xlabelsize=22, ylabelsize=22,
                                    xticklabelsize=18, yticklabelsize=18); draw_map!(ax)
                end
                view in ("end", "side", "3d") && Legend(g[2, 1], legend_elems, legend_labels; orientation=:horizontal, nbanks=2, tellwidth=false,
                    labelsize=18, labelcolor=th.fg, framevisible=false, backgroundcolor=(th.bg, 0), patchsize=(30, 12), colgap=20)
                savefig(g, "$(name)_$(view)_$tname")
            end
        end
    end
    name
end

# ── interactive pages ────────────────────────────────────────────────────────
const HTMLPAGES = Dict{String,Dict{String,Any}}()
"""One self-contained page per event: tracks as tubes, calorimeter energy as towers from the inner
face of each calorimeter (length logarithmic in energy), V⁰ vertices, sphericity axis and the
detector wireframe. Linear geometry; coordinates in cm."""
function write_html(name, run, evn, label, paths, em, hc, V, ax3, ngood, nneu, evis, emunsel=Set{Int}())
    r1(v) = round.(collect(v); digits=1)
    fmt(x; d=2) = isfinite(x) ? round(x; digits=d) : nothing
    function info(t)
        pt = t.p === nothing ? NaN : hypot(t.p[1], t.p[2]); pp = t.p === nothing ? NaN : norm(t.p)
        Dict("p" => fmt(pp), "pt" => fmt(pt), "q" => Int(t.q), "hits" => t.hits, "d0" => fmt(t.d0; d=3), "z0" => fmt(t.z0; d=3),
             "chi2" => fmt(t.chi2; d=1), "ndf" => Int(t.ndf), "dedx" => fmt(t.dedxpad[1]; d=3), "dedxerr" => fmt(t.dedxpad[2]; d=3),
             "dedxw" => fmt(t.dedxwire[1]; d=3), "cth" => t.p === nothing ? nothing : fmt(t.p[3] / pp; d=3))
    end
    tr = [Dict("c" => p.v0 ? "v0" : p.good ? "sel" : "oth", "p" => [r1(q) for q in p.pts[1:max(1, length(p.pts) ÷ 120):end]],
               "h" => Vector{Vector{Float64}}([[round(h[1]; digits=1), round(h[2]; digits=1), round(h[3]; digits=1), h[4]] for h in p.hits]), "i" => info(p.t))
          for p in paths if length(p.pts) >= 2]
    bl(E, full) = full * clamp(log1p(E) / log1p(25.0), .06, 1.2)
    bars = Dict{String,Any}[]
    for (c, k, full) in ((em, "em", 55.0), (hc, "hc", 150.0)), i in eachindex(c.E)
        a0 = (c.x[i], c.y[i], c.z[i]); L = bl(c.E[i], full)
        push!(bars, Dict("k" => k, "e" => round(c.E[i]; digits=2), "a" => r1(a0), "b" => r1(a0 .+ L .* c.u[i]), "u" => k == "em" && i in emunsel))
    end
    HTMLPAGES[name] = Dict{String,Any}("name" => name, "experiment" => EXPERIMENT, "run" => run, "event" => evn, "label" => label,
                "tracks" => tr, "bars" => bars, "v0" => Vector{Vector{Float64}}([r1(v.pos) for v in V]), "axis" => collect(ax3),
                "nsel" => ngood, "nneu" => nneu, "nv0" => length(V), "evis" => evis,
                "geom" => Dict(String(k) => collect(v) for (k, v) in pairs(G)), "prev" => "", "next" => "")
end
function finish_html(dir, order)
    mkpath(dir); tpl = read(joinpath(@__DIR__, "src", "viewer3d.html"), String)
    # three.js is shipped next to the pages (lib/) so they also work offline.
    mkpath(joinpath(dir, "lib"))
    for f in ("three.min.js", "OrbitControls.js"); cp(joinpath(@__DIR__, "src", "vendor", f), joinpath(dir, "lib", f); force=true); end
    for (k, name) in enumerate(order)
        d = HTMLPAGES[name]
        d["prev"] = k > 1 ? order[k-1] * ".html" : ""; d["next"] = k < length(order) ? order[k+1] * ".html" : ""
        write(joinpath(dir, name * ".html"), replace(tpl, "/*DATA*/" => JSON.json(d)))
    end
    esc(s) = replace(s, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
    rows = join(["<a class=\"ev\" href=\"$(n).html\"><span class=\"r\">run $(HTMLPAGES[n]["run"]) · event $(HTMLPAGES[n]["event"])</span><span class=\"i\">$(esc(HTMLPAGES[n]["label"]))</span></a>" for n in order], "\n")
    write(joinpath(dir, "index.html"), """<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ALEPH events</title><style>:root{--bg:#07080C;--fg:#ECECF2;--muted:#80869A;--line:#2A2F40;--track:#B3A6FF}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:960px;margin:auto;padding:32px 16px}h1{font-size:22px;margin:0 0 4px}p{color:var(--muted);margin:0 0 20px}
.ev{display:grid;grid-template-columns:220px 1fr;gap:14px;align-items:baseline;padding:9px 12px;border-top:1px solid var(--line);color:var(--fg);text-decoration:none}
.ev:hover{background:#121520}.i{font-weight:700;color:var(--track)}.r{font-variant-numeric:tabular-nums}
@media(max-width:600px){.ev{grid-template-columns:1fr}}</style></head><body><main>
<h1>$(esc(EXPERIMENT)) — interactive event displays</h1><p>$(length(order)) event$(length(order) == 1 ? "" : "s"). Each page opens in 3D; drag to rotate, scroll to zoom.</p>
$rows
</main></body></html>""")
    @info "interactive pages: $(joinpath(dir, "index.html"))"
end

names = [draw_event(d, T, V, ev.entry, ev.label) for (ev, d, T, V) in zip(events, data, alltracks, allv0)]
a["no-html"] || finish_html(joinpath(OUT, "html"), unique(names))
@info "done: $(length(names)) event(s) in $OUT"

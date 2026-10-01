extends RefCounted
class_name ModOrder
## Resolves the order mods load in, so a mod always runs after the mods it depends on.
##
## Split out of `ModHost` because it is a self-contained algorithm rather than loader
## plumbing, and because it carries a promise the rest of the project leans on: the
## docs state that the same set of mods loads in the same order every run. That promise
## is what makes a seeded world reproducible when mods reshape terrain, and it is why
## this file has its own assertions in `tools/runtime_self_test.gd`.
##
## The traversal is depth-first with an explicit stack rather than recursion, so a
## pathological dependency chain cannot overflow the call stack. Every degenerate case
## degrades instead of failing the load:
##
##   - a dependency on a mod that is not installed warns and is ignored;
##   - a chain deeper than `MAX_DEPENDENCY_DEPTH` is abandoned at that point;
##   - a **cycle** is cut at the edge that would close it, so every mod still appears
##     exactly once. Mods on a cycle load in an order determined by their dependency
##     edges, which is deterministic but is not id order.
##
## The cycle rule is the one that used to be wrong: the traversal only skipped
## *finished* mods, so a mod that depended on an ancestor was pushed again, and a pair
## declaring each other recursively appended itself until the depth guard stopped it —
## producing a load order of 64 entries for 2 mods, and therefore 64 instantiations.
## Tracking the mods on the current path as well as the finished ones is what makes the
## traversal terminate at the cycle instead of grinding into the guard.
##
## Mods are additive by contract: a broken dependency graph must never be able to stop
## the game from booting.

## Guard against a pathological chain of mod dependencies.
const MAX_DEPENDENCY_DEPTH: int = 64


## Candidates in load order. Each entry is the dictionary `ModHost` scanned, and must
## carry `id` plus an optional `dependencies`.
static func order(candidates: Array[Dictionary]) -> Array[Dictionary]:
	var by_id: Dictionary = {}
	var sorted_candidates: Array[Dictionary] = candidates.duplicate()
	sorted_candidates.sort_custom(_id_before)
	for candidate: Dictionary in sorted_candidates:
		by_id[String(candidate["id"])] = candidate

	var ordered: Array[Dictionary] = []
	## Finished: already emitted.
	var visited: Dictionary = {}
	## On the current path: a dependency pointing at one of these is a cycle edge.
	var visiting: Dictionary = {}
	var visit_sequence: int = 0

	for root: Dictionary in sorted_candidates:
		var root_id: String = String(root["id"])
		if visited.has(root_id):
			continue
		var stack: Array[Dictionary] = [{"node": root, "deps": [], "index": 0}]
		visiting[root_id] = true

		while not stack.is_empty():
			var frame: Dictionary = stack[-1]
			var node: Dictionary = frame["node"]
			var node_id: String = String(node["id"])

			if frame["deps"].is_empty():
				if visited.has(node_id):
					visiting.erase(node_id)
					stack.pop_back()
					continue
				if stack.size() > MAX_DEPENDENCY_DEPTH:
					push_warning("[ModOrder] dependency chain deeper than %d at '%s'; using id order for the remainder" % [MAX_DEPENDENCY_DEPTH, node_id])
					visiting.erase(node_id)
					stack.pop_back()
					continue
				var resolved: Array[Dictionary] = []
				for dependency: String in (node.get("dependencies", PackedStringArray()) as PackedStringArray):
					if not by_id.has(dependency):
						push_warning("[ModOrder] mod '%s' depends on '%s', which is not installed" % [node_id, dependency])
						continue
					# Finished dependencies are done; dependencies still on the current
					# path would close a cycle, so the edge is dropped rather than
					# followed. These two tests together are what make the traversal
					# terminate on any graph.
					if not visited.has(dependency) and not visiting.has(dependency):
						resolved.append(by_id[dependency])
				resolved.sort_custom(_id_before)
				frame["deps"] = resolved

			var deps: Array = frame["deps"]
			var index: int = int(frame["index"])
			if index < deps.size():
				frame["index"] = index + 1
				var dependency_node: Dictionary = deps[index]
				var dependency_id: String = String(dependency_node["id"])
				if not visited.has(dependency_id) and not visiting.has(dependency_id):
					stack.append({"node": dependency_node, "deps": [], "index": 0})
					visiting[dependency_id] = true
				continue

			visited[node_id] = visit_sequence
			visit_sequence += 1
			ordered.append(node)
			visiting.erase(node_id)
			stack.pop_back()
	return ordered


## Ties are broken by id, which is the other half of "the same mods always load in the
## same order": without it the order would depend on directory iteration.
static func _id_before(a: Dictionary, b: Dictionary) -> bool:
	return String(a["id"]) < String(b["id"])

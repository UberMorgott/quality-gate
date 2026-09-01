---
name: Gate is wrong
about: The gate crashed, blamed correct code, missed a stack, or cannot be satisfied
title: ''
labels: bug
---

<!-- Filed by a human or by an agent that the gate blocked. Keep it factual. -->

**What I ran**

```
qgate ...
```

**What it printed**

```
<paste the gate output, including the [FAIL]/[WARN] lines>
```

**Why the gate is wrong here**

<!-- e.g. the file it blamed is correct, the phase crashed, a stack was skipped,
     no possible edit makes it pass -->

**Install**

```
<paste `qgate where` -- install path and commit>
```

**Repo shape**

<!-- which stacks (go / web / rust), where their marker files live, monorepo or not -->

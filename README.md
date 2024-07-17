# Parallel property-based testing with a deterministic thread scheduler

This post is about how to write tests that can catch race conditions in
a reproducible way. The approach is programming language agnostic, and
should work in most languages that have a decent multi-threaded story.
It's a white-box testing approach, meaning you will have to modify the
software under test.

## Background

In my previous
[post](https://stevana.github.io/the_sad_state_of_property-based_testing_libraries.html),
we had a look at how to mechanically derive parallel tests that can
uncover race conditions from a sequential (single-threaded) fake (think
more elaborate test double than a mock).

One of the nice things about the approach is that it's a black-box
testing technique, i.e. it doesn't require the user to change the
software under test.

One big downside is that because threads will interleave differently
when we rerun the tests, there by potentially causing different
outcomes. This in turn creates problems for the shrinking of failing
test cases.

Workaround, module swap, grey-box?

Not satisfactory and I left a todo item to implement a determinstic
scheduler, like in the PULSE paper

Finding Race Conditions in Erlang with QuickCheck and PULSE (ICFP 2009)
<https://www.cse.chalmers.se/~nicsma/papers/finding-race-conditions.pdf>

the pulse scheduler was
[supposedly](http://quviq.com/documentation/pulse/index.html) released
under the bsd license, but i've not been able to find it.

because of the way Erlang works with everything being triggered by
messages, it seems reasonable that the PULSE scheduler merely acts as a
man-in-the-middle proxy

i implemented something like this 6 years ago:
<https://github.com/advancedtelematic/quickcheck-state-machine-distributed#readme>

but i didn't know how to do it in a non-actor setting.

I was therefore happy to see that my post inspired matklad's
[post](https://matklad.github.io/2023/07/05/properly-testing-concurrent-data-structures.html)

In this post I'll port matklad's approach from Rust to Haskell and hook
it up to the parallel property-based testing machinary from my previous
post.

- difference to matklad's post? (he doesn't use linearisability
  checking)

## Overview / motivation

In order to explain what we'd like to do, it's helpful to consider an
example of a race condition.

counter, two concurrent increments

different interleavings, we'd like to control which happens

matklad's idea: insert pauses between each shared memory operation, have
a scheduler unpause one thread at the time

## Deterministic scheduler

The unpausing by the scheduler needs to happen via some channel, we'll
use Haskell's `TMVar`s of this. `MVar`s can be thought of boxes that
contain a value, where taking something out of a box that is empty
blocks and putting something into a box that is full blocks as well. The
`T` in `TMVar`s merely adds STM transactions around `MVar`s.

``` haskell
data Signal = SingleThreaded | MultiThreaded (TMVar ())
  deriving Eq
```

## Parallel property-based testing recap

In our counter example above, we had two concurrent increments, in this
case it's easy to see what the answer must be (the counter must have the
value of two, if we start counting from zero and increment by one).

However for more complicated scenarios it gets less clear, consider:

- two concurrent incrs + get
- crashing threads

Luckily there's a correctness criteria for concurrent programs like
these which is based on a sequential model:

Linearizability: a correctness condition for concurrent objects by
Herlihy and Wing (1990)
<https://cs.brown.edu/~mph/HerlihyW90/p463-herlihy.pdf>

this is what we use in parallel property-based testing (and also what
Jepsen's Knossos checker uses)

The idea in a nutshell: execute commands in parallel, collect a
concurrent history of when each command started and stopped executing,
try to find an interleaving of commands which satisfies the sequential
model.

## Integrating the scheduler into the testing

I don't want to reimplement the parallel property-based testing
machinary from my previous post here, but merely show that integrating
the deterministic scheduler isn't too much work.

``` diff
```

## Conclusion and further work

- some seeds don't give the minimal counterexample, shrinking can be
  improved as already pointed out in my previous post

- enumarate all interleavings upto some depth, model checking style,
  perhaps using smallcheck? Compare to dejafu library

- while this approach works in all languages due to its white-box
  nature, what would it take to have a black-box approach that's
  deterministic?

  - intercept syscalls rr (and hermit?)
  - hypervisor (Antithesis)
  - language support for user schedulers

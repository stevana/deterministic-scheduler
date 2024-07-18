# Parallel property-based testing with a deterministic thread scheduler

*Work in progress, please don't share, but do feel free to get
involved!*

This post is about how to write tests that can catch race conditions in
a reproducible way. The approach is programming language agnostic, and
should work in most languages that have a decent multi-threaded story.
It's a white-box testing approach, meaning you will have to modify the
software under test.

## Background

In my previous
[post](https://stevana.github.io/the_sad_state_of_property-based_testing_libraries.html),
we had a look at how to mechanically derive parallel tests that can
uncover race conditions from a sequential fake[^1].

One of the nice things about the approach is that it's a black-box
testing technique, i.e. it doesn't require the user to change the
software under test.

One big downside is that because threads will interleave differently
when we rerun the tests, there by potentially causing different
outcomes. This in turn creates problems for the shrinking of failing
test cases[^2].

As a workaround, I suggested that when a race condition is found in the
unmodified code, one could swap the shared memory module for one that
introduces sleeps around the operations. This creates less
non-determinism, because the jitter of each operation will have less of
an impact, and therefore helps shrinking.

This isn't a satisfactory solution, of course, and I left a to do item
to implement a determinstic scheduler, like the authors do in the
[paper](https://www.cse.chalmers.se/~nicsma/papers/finding-race-conditions.pdf)
that first introduced parallel property-based testing.

The idea of the deterministic scheduler is that it should be possible to
rerun a multi-threaded program and get exactly the same interleaving of
threads each time.

The deterministic scheduler from the above mentioned paper is called
PULSE. It was
[supposedly](http://quviq.com/documentation/pulse/index.html) released
under the BSD license, however I've not been able to find it.

PULSE is written in Erlang and the paper uses it to test Erlang code. In
Erlang everything is triggered by message passing, so I think that the
correct way of thinking about what PULSE does is that it acts as a
person-in-the-middle proxy. With other words, an Erlang process doesn't
send a messaged directly to another process, but instead asks the
scheduler to send it to the process. That way all messages go via the
scheduler and it can choose the message order. Note that a seed can be
used to introduce randomness, without introducing non-determinism.

I implemented a proxy scheduler like this in Haskell (using
`distributed-process`, think Haskell trying to be like Erlang) about 6
years
[ago](https://github.com/advancedtelematic/quickcheck-state-machine-distributed#readme),
but I didn't know how to do it in a non-message-passing setting.

I was therefore happy to see that my post inspired matklad to write a
[post](https://matklad.github.io/2023/07/05/properly-testing-concurrent-data-structures.html)
where he shows how he'd do it in a multi-threaded shared memory setting.

In this post I'll port matklad's approach from Rust to Haskell and hook
it up to the parallel property-based testing machinary from my previous
post.

Another difference between matklad and the approach in this post is that
matklad uses an ad-hoc correctness criteria, whereas I follow the
parallel property-based testing paper and use
[linearisability](https://cs.brown.edu/~mph/HerlihyW90/p463-herlihy.pdf).

An ad-hoc criteria can be faster than linearisability checking, but
depending on how complicated your system is, it might be harder to find
one. Linearisability checking on the other hand follows mechanically
(for free) from a sequential (single-threaded) model/fake.

If you know what you are doing, then by all means figure out an ad-hoc
correctness criteria like matklad does. If on the otherhand you haven't
tested much concurrent code before, then I'd recommend starting with the
linearisability checking approach that we are about to describe[^3].

## Motivation and overview

In order to explain what we'd like to do, it's helpful to consider an
example of a race condition.

counter, two concurrent increments
<https://en.m.wikipedia.org/wiki/Database_transaction_schedule>

different interleavings, we'd like to control which happens

matklad's idea: insert pauses between each shared memory operation, have
a scheduler unpause one thread at the time

- deterministic scheduler
- parallel property-based testing recap
- integrating the deterministic scheduler with parallel property-based
  testing

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

``` haskell
newSingleThreadedSignal :: Signal
newSingleThreadedSignal = SingleThreaded

newMultiThreadedSignal :: IO Signal
newMultiThreadedSignal = MultiThreaded <$> newEmptyTMVarIO
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

[^1]: If you haven't heard of
    [fakes](https://martinfowler.com/bliki/TestDouble.html) before,
    think of them as a more elaborate test double than a mock. A mock of
    a component expects to be called in some particular way (i.e.
    exposes only some limited subset of the components API), and
    typically throw an expeception when called in any other way. While a
    fake exposes the full API and can be called just like the real
    component, but unlike the real component it takes some shortcuts.
    For example a fake might lose all data when restarted (i.e. keeps
    all data in memory, while the real component persists the data to
    some stable storage).

[^2]: The reason for shrinking not working so well with non-determinism
    is because shrinking stops when the property passes. So if some
    input causes the property to fail and then we rerun the property on
    a smaller input it might be the case that the smaller input still
    contains the race condition, but because the interleaving of threads
    is non-deterministic we are unlucky and the race condition isn't
    triggered and the property passes, which stops the shrinking
    process.

[^3]: Jepsen's [Knossos
    checker](https://aphyr.com/posts/314-computational-techniques-in-knossos)
    also uses linearisability checking and has found many
    [bugs](https://jepsen.io/analyses), so we are in good company.

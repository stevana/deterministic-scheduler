# Parallel property-based testing with a deterministic thread scheduler

This post is about how to write tests that can catch race conditions in a
reproducible way. The approach is programming language agnostic, and should
work in most languages that have a decent multi-threaded story. It's a
white-box testing approach, meaning you will have to modify the software under
test.

## Background

In my previous
[post](https://stevana.github.io/the_sad_state_of_property-based_testing_libraries.html),
we had a look at how to mechanically derive parallel tests that can uncover
race conditions from a sequential (single-threaded) fake (think more elaborate
test double than a mock).

One of the nice things about the approach is that it's a black-box testing
technique, i.e. it doesn't require the user to change the software under test. 

One big downside is that because threads will interleave differently when we
rerun the tests, there by potentially causing different outcomes. This in turn
creates problems for the shrinking of failing test cases.

Workaround, module swap, grey-box?

Not satisfactory and I left a todo item to implement a determinstic scheduler,
like in the PULSE paper

the pulse scheduler was
[supposedly](http://quviq.com/documentation/pulse/index.html) released under
the bsd license, but i've not been able to find it.

because of the way Erlang works with everything being triggered by messages, it
seems reasonable that the PULSE scheduler merely acts as a man-in-the-middle proxy

i implemented something like this 6 years ago:
https://github.com/advancedtelematic/quickcheck-state-machine-distributed#readme

but i didn't know how to do it in a non-actor setting.

I was therefore happy to see that my post inspired matklad's
[post](https://matklad.github.io/2023/07/05/properly-testing-concurrent-data-structures.html)

In this post I'll port matklad's approach to Haskell and hook it up to the
parallel property-based testing machinary from my previous post.

## Overview / motivation



## Deterministic scheduler

``` {.haskell include=src/ManagedThread2.hs snippet=Signal .numberLines}
```

## Parallel property-based testing recap

## Integrating the scheduler into the testing

## Conclusion and further work

* some seeds don't give the minimal counterexample, shrinking can be improved
  as already pointed out in my previous post

* enumarate all interleavings upto some depth, model checking style, perhaps
  using smallcheck? Compare to dejafu library

* while this approach works in all languages due to its white-box nature, what
  would it take to have a black-box approach that's deterministic?

# Parallel property-based testing with a deterministic thread scheduler

* follow up to my previous
  [post](https://stevana.github.io/the_sad_state_of_property-based_testing_libraries.html)
* technical writing that's not specific to one language community is tricky
* matklad's
  [post](https://matklad.github.io/2023/07/05/properly-testing-concurrent-data-structures.html)
* http://quviq.com/documentation/pulse/index.html

## Deterministic scheduler

``` {include="src/ManagedThread2.hs" .haskell snippet="Signal" .numberLines}
```

## Parallel property-based testing recap

## Integrating the scheduler into the testing

## Conclusion and further work

* some seeds don't give the minimal counterexample, shrinking can be improved
  as already pointed out in my previous post

* enumarate all interleavings upto some depth, model checking style, perhaps
  using smallcheck? Compare to dejafu library


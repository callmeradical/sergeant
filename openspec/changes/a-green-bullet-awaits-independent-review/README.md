# a-green-bullet-awaits-independent-review

A factory may configure a `review` pipeline phase that dispatches a fresh, context-isolated agent to judge a bullet's diff against its intent and OpenSpec change before the bullet is eligible for sealing; a blocking finding sends the bullet to the existing `blocked` state instead, and a non-blocking finding is just recorded, so a bullet with no review phase configured behaves exactly as it does today.

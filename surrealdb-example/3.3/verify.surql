-- Expected after a good restore: products=5, customers=3, orders=5,
-- alice_total=110, bob_total=160, chen_total=105, and the unique index exists.
RETURN { products:    count(SELECT * FROM product), customers:   count(SELECT * FROM customer), orders:      count(SELECT * FROM ordered), alice_total: fn::order_total(customer:alice), bob_total:   fn::order_total(customer:bob), chen_total:  fn::order_total(customer:chen), has_index:   (INFO FOR TABLE product).indexes.product_name != NONE };

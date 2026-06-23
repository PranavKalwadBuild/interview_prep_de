# End‑to‑End Retail Data Modeling with OOP (Pythonic)

This document presents a complete, object‑oriented model of a typical retail data warehouse (star schema) using modern Python best practices. The model covers:

* **Dimension tables** – descriptive, slowly changing attributes (SCD‑type 1/2 patterns are shown where relevant).
* **Fact table** – quantitative measurements that link to dimensions.
* **Relationships** – expressed via composition / references, surrogate keys, and helper methods.
* **Pythonic conventions** – type hints, dataclasses, `__post_init__` validation, properties, `__repr__`, `__eq__`, hashing, and optional use of **Pydantic** for robust validation.
* **Extensibility** – how to add new dimensions, facts, or slowly‑changing logic without breaking existing code.

The code snippets are deliberately self‑contained so they can be copied into a module (e.g., `retail_model.py`) and used directly in unit tests, ETL pipelines, or as an ORM‑agnostic domain model.

---

## 1. Core Concepts & Naming Conventions

| Concept | Pythonic representation | Reasoning |
|---------|------------------------|----------|
| **Surrogate key** | `int` attribute named `sk_<entity>` (e.g., `sk_customer`) | Guarantees join stability even if natural keys change. |
| **Natural key** | One or more fields that uniquely identify the real‑world entity (e.g., `customer_id`). | Useful for lookup and source system integration. |
| **Immutable dimension rows** | After creation, attributes that define the dimension version should not change (use `@property` without setter or `frozen=True` in dataclasses). | Prevents accidental corruption of historical snapshots. |
| **Mutable fact fields** | Numeric measures (e.g., `quantity`, `amount`) are plain attributes; they may be updated during ETL loads. | Facts are typically append‑only, but measures can be corrected. |
| **Validation** | Performed in `__post_init__` (dataclasses) or via Pydantic validators. | Guarantees objects are always in a valid state. |
| **Factory / builder patterns** | Class methods like `from_source(row: dict)` allow creation from raw extraction data. | Keeps `__init__` clean and encapsulates transformation logic. |
| **Representation** | `__repr__` shows key attributes; `__str__` can be more user‑friendly. | Helps debugging and logging. |
| **Hashability** | If an object is immutable (e.g., a dimension row), implement `__hash__` so it can be used in sets or as dict keys. | Enables efficient deduplication in‑memory. |

---

## 2. Shared Base Classes

```python
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any, Dict, Iterable, Optional
import datetime as dt


@dataclass(eq=False, unsafe_hash=False)
class BaseModel:
    """Common behavior for all model objects."""
    sk: int = field(compare=False, hash=False)  # surrogate key

    def __post_init__(self) -> None:
        if self.sk < 0:
            raise ValueError("Surrogate key must be non‑negative")

    def __repr__(self) -> str:
        cls = self.__class__.__name__
        attrs = ", ".join(f"{k}={v!r}" for k, v in self.__dict__.items() if not k.startswith("_"))
        return f"<{cls}({attrs})>"

    def as_dict(self) -> Dict[str, Any]:
        """Return a plain dict – useful for serialization or bulk insert."""
        return {k: v for k, v in self.__dict__.items() if not k.startswith("_")}
```

*Why `eq=False`?* We'll define equality based on natural keys (where relevant) rather than surrogate keys, which differ per load.

---

## 3. Dimension Models

### 3.1 Customer (Type‑2 SCD example)

```python
@dataclass(eq=False, unsafe_hash=False)
class Customer(BaseModel):
    """
    Customer dimension – illustrates a Type‑2 slowly changing dimension.
    Fields that trigger a new row when changed: name, email, tier, address.
    """
    # Natural key from source system
    customer_id: str
    # Attributes that may change over time
    name: str
    email: str
    tier: str                     # e.g., 'Bronze', 'Silver', 'Gold'
    address: str
    is_active: bool = True       # Soft‑delete flag (optional)

    # Type‑2 specific columns
    valid_from: dt.date = field(default_factory=dt.date.today)
    valid_to: dt.date = dt.date(9999, 12, 31)  # far‑future = current row
    is_current: bool = True

    def __post_init__(self) -> None:
        super().__post_init__()
        if not self.customer_id:
            raise ValueError("customer_id is required")
        if self.valid_to < self.valid_from:
            raise ValueError("valid_to must be >= valid_from")
        # Normalize email for comparison (case‑insensitive)
        object.__setattr__(self, "email", self.email.lower().strip())

    # ---- Equality based on natural key (for change detection) ----
    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Customer):
            return NotImplemented
        return self.customer_id == other.customer_id

    def __hash__(self) -> int:
        return hash(self.customer_id)

    # ---- Helper to detect if a non‑key attribute changed ----
    def has_changed(self, other: "Customer") -> bool:
        """Return True if any tracked attribute differs (excluding surrogate & Type‑2 cols)."""
        tracked = ("name", "email", "tier", "address", "is_active")
        return any(getattr(self, attr) != getattr(other, attr) for attr in tracked)

    # ---- Factory from raw source dict ----
    @classmethod
    def from_source(cls, sk: int, data: Dict[str, Any]) -> "Customer":
        """
        Build a Customer instance from a source record.
        `data` is expected to contain the natural key and current attribute values.
        """
        return cls(
            sk=sk,
            customer_id=data["customer_id"],
            name=data["name"],
            email=data["email"],
            tier=data.get("tier", "Bronze"),
            address=data.get("address", ""),
            is_active=data.get("is_active", True),
            valid_from=dt.date.today(),
            valid_to=dt.date(9999, 12, 31),
            is_current=True,
        )
```

*Notes*  
* `has_changed` is used by the ETL layer to decide whether to expire the current row and insert a new version.  
* The class is hashable by `customer_id`; this enables quick look‑ups in a dictionary keyed by natural key.

### 3.2 Product (Type‑1 SCD – overwrites)

```python
@dataclass(eq=False, unsafe_hash=False)
class Product(BaseModel):
    """Product dimension – Type‑1 (overwrite) for simplicity."""
    product_id: str          # natural key (SKU or UPC)
    brand: str
    category: str
    subcategory: str
    unit_price: float        # current selling price
    cost_price: float
    is_discontinued: bool = False

    def __post_init__(self) -> None:
        super().__post_init__()
        if not self.product_id:
            raise ValueError("product_id required")
        if self.unit_price < 0 or self.cost_price < 0:
            raise ValueError("Prices must be non‑negative")

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Product):
            return NotImplemented
        return self.product_id == other.product_id

    def __hash__(self) -> int:
        return hash(self.product_id)

    @classmethod
    def from_source(cls, sk: int, data: Dict[str, Any]) -> "Product":
        return cls(
            sk=sk,
            product_id=data["product_id"],
            brand=data["brand"],
            category=data["category"],
            subcategory=data["subcategory"],
            unit_price=float(data["unit_price"]),
            cost_price=float(data["cost_price"]),
            is_discontinued=data.get("is_discontinued", False),
        )
```

### 3.3 Store (Type‑1)

```python
@dataclass(eq=False, unsafe_hash=False)
class Store(BaseModel):
    """Store dimension."""
    store_id: str           # natural key
    name: str
    format: str             # e.g., 'Supermarket', 'Convenience', 'Online'
    city: str
    state: str
    country: str
    open_date: dt.date
    is_active: bool = True

    def __post_init__(self) -> None:
        super().__post_init__()
        if not self.store_id:
            raise ValueError("store_id required")
        if self.open_date > dt.date.today():
            raise ValueError("open_date cannot be in the future")

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Store):
            return NotImplemented
        return self.store_id == other.store_id

    def __hash__(self) -> int:
        return hash(self.store_id)

    @classmethod
    def from_source(cls, sk: int, data: Dict[str, Any]) -> "Store":
        return cls(
            sk=sk,
            store_id=data["store_id"],
            name=data["name"],
            format=data["format"],
            city=data["city"],
            state=data["state"],
            country=data["country"],
            open_date=dt.date.fromisoformat(data["open_date"]),
            is_active=data.get("is_active", True),
        )
```

### 3.4 Date (Time) Dimension – pre‑generated surrogate key

```python
@dataclass(eq=False, unsafe_hash=False)
class DateDim(BaseModel):
    """Date dimension – one row per calendar day."""
    date: dt.date
    day: int = field(init=False)
    month: int = field(init=False)
    quarter: int = field(init=False)
    year: int = field(init=False)
    day_of_week: int = field(init=False)   # Monday=0, Sunday=6
    day_name: str = field(init=False)
    month_name: str = field(init=False)
    is_weekend: bool = field(init=False)
    is_holiday: bool = False               # can be set later via lookup

    def __post_init__(self) -> None:
        super().__post_init__()
        # Derive calendar attributes
        self.day = self.date.day
        self.month = self.date.month
        self.quarter = (self.month - 1) // 3 + 1
        self.year = self.date.year
        self.day_of_week = self.date.weekday()  # Monday=0
        self.day_name = self.date.strftime("%A")
        self.month_name = self.date.strftime("%B")
        self.is_weekend = self.day_of_week >= 5  # Sat/Sun

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, DateDim):
            return NotImplemented
        return self.date == other.date

    def __hash__(self) -> int:
        return hash(self.date)

    @classmethod
    def from_date(cls, sk: int, date: dt.date) -> "DateDim":
        return cls(sk=sk, date=date)
```

*Usage*: ETL populates this dimension once (or incrementally) and reuses the surrogate keys for all fact rows.

---

## 4. Fact Model

### 4.1 Sales Fact (grain: one line item per transaction)

```python
@dataclass(eq=False, unsafe_hash=False)
class SalesFact(BaseModel):
    """
    Fact table capturing a single line‑item sale.
    Foreign keys point to dimension surrogate keys.
    Measures are numeric and additive.
    """
    # Foreign keys to dimensions
    sk_customer: int
    sk_product: int
    sk_store: int
    sk_date: int

    # Optional degenerate dimension (transaction identifier from source)
    transaction_id: str
    line_number: int = 1

    # Measures
    quantity: int = 1
    unit_price: float = field(compare=False)   # price at sale time (may differ from current product.price)
    discount_amount: float = 0.0
    tax_amount: float = 0.0
    # Derived measure (can be computed property)
    @property
    def net_amount(self) -> float:
        """Quantity * unit_price – discount + tax."""
        return self.quantity * self.unit_price - self.discount_amount + self.tax_amount

    def __post_init__(self) -> None:
        super().__post_init__()
        if any(x < 0 for x in (self.quantity, self.unit_price, self.discount_amount, self.tax_amount)):
            raise ValueError("Quantity and monetary amounts must be non‑negative")
        if self.transaction_id == "":
            raise ValueError("transaction_id required")
        if self.line_number < 1:
            raise ValueError("line_number must be >= 1")

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, SalesFact):
            return NotImplemented
        # Fact equality can be based on the combination of all keys + line number
        return (
            self.sk_customer == other.sk_customer
            and self.sk_product == other.sk_product
            and self.sk_store == other.sk_store
            and self.sk_date == other.sk_date
            and self.transaction_id == other.transaction_id
            and self.line_number == other.line_number
        )

    def __hash__(self) -> int:
        return hash(
            (
                self.sk_customer,
                self.sk_product,
                self.sk_store,
                self.sk_date,
                self.transaction_id,
                self.line_number,
            )
        )

    @classmethod
    def from_source(
        cls,
        sk: int,
        *,
        sk_customer: int,
        sk_product: int,
        sk_store: int,
        sk_date: int,
        transaction_id: str,
        line_number: int,
        quantity: int,
        unit_price: float,
        discount_amount: float = 0.0,
        tax_amount: float = 0.0,
    ) -> "SalesFact":
        """Factory that mirrors the shape of a typical staging row."""
        return cls(
            sk=sk,
            sk_customer=sk_customer,
            sk_product=sk_product,
            sk_store=sk_store,
            sk_date=sk_date,
            transaction_id=transaction_id,
            line_number=line_number,
            quantity=quantity,
            unit_price=unit_price,
            discount_amount=discount_amount,
            tax_amount=tax_amount,
        )
```

*Why store `unit_price` in the fact?*  
The price can diverge from the current `Product.unit_price` due to promotions, contracts, or temporal changes – storing it makes the fact self‑contained for point‑in‑time reporting.

---

## 5. Relationships & Navigation Helpers (Optional)

While a pure OOP model does not enforce referential integrity, convenience methods can make navigation clearer in unit tests or in‑memory analytics.

```python
# Example: given a SalesFact, retrieve linked dimension objects from lookup dicts
def attach_dimensions(
    fact: SalesFact,
    customers: Dict[int, Customer],
    products: Dict[int, Product],
    stores: Dict[int, Store],
    dates: Dict[int, DateDim],
) -> SalesFact:
    """
    Returns a new SalesFact instance with attached dimension objects
    stored as private attributes (for convenience, not persisted).
    """
    fact._customer = customers.get(fact.sk_customer)
    fact._product = products.get(fact.sk_product)
    fact._store = stores.get(fact.sk_store)
    fact._date = dates.get(fact.sk_date)
    return fact

# Usage in a reporting loop:
# for f in facts:
#     attach_dimensions(f, cust_lkp, prod_lkp, store_lkp, date_lkp)
#     print(f.net_amount, f._customer.name, f._product.category, f._date.isoformat())
```

These helpers keep the core model free of ORM‑specific code while still offering ergonomic access when needed.

---

## 6. Validation & Testing Strategies (Pytest)

Because each class is small and focused, unit testing is straightforward.

```python
# test_retail_model.py
import pytest
from retail_model import (
    Customer,
    Product,
    Store,
    DateDim,
    SalesFact,
)

def test_customer_creation_and_change_detection():
    src = {
        "customer_id": "CUST-001",
        "name": "Alice Smith",
        "email": "ALICE@EXAMPLE.COM",
        "tier": "Silver",
        "address": "123 Main St",
        "is_active": True,
    }
    c1 = Customer.from_source(sk=1, data=src)
    assert c1.email == "alice@example.com"   # normalized
    assert c1.is_current is True

    # Simulate a change: tier updated
    src2 = src.copy()
    src2["tier"] = "Gold"
    c2 = Customer.from_source(sk=2, data=src2)
    assert c1.has_changed(c2) is True   # name, email, address same, tier diff

def test_salesfact_net_amount_property():
    f = SalesFact.from_source(
        sk=10,
        sk_customer=1,
        sk_product=2,
        sk_store=3,
        sk_date=4,
        transaction_id="TXN-999",
        line_number=1,
        quantity=3,
        unit_price=10.0,
        discount_amount=2.0,
        tax_amount=1.5,
    )
    assert f.net_amount == (3 * 10.0) - 2.0 + 1.5   # 30 -2 +1.5 = 29.5

def test_date_dim_calendar_attributes():
    d = DateDim.from_date(sk=100, date=dt.date(2024, 2, 29))  # leap year
    assert d.day == 29
    assert d.month == 2
    assert d.year == 2024
    assert d.is_weekend is False   # 2024‑02‑29 is a Thursday
```

*Best practices demonstrated*:
* **Deterministic equality & hashing** enables using objects in sets/dicts for deduplication.
* **Factory methods** (`from_source`, `from_date`) keep `__init__` clean and centralize conversion logic.
* **Properties** for derived measures (`net_amount`) avoid storing redundant data.
* **Validation** in `__post_init__` catches malformed data early.
* **Type hints** throughout improve IDE support and readability.
* **Immutability hints** – although we didn’t freeze the dataclasses (to allow ETL updates), the design encourages treating dimension rows as immutable after creation; you can replace them with `frozen=True` if you prefer strict immutability.

---

## 7. Extending the Model

### Adding a New Dimension (e.g., Promotion)

1. Create a `@dataclass` inheriting from `BaseModel`.
2. Define natural key and descriptive attributes.
3. Implement `__eq__`, `__hash__`, and a `from_source` factory.
4. If the dimension is slowly changing, add Type‑2 columns (`valid_from`, `valid_to`, `is_current`) and a `has_changed` method.
5. Add the foreign key (`sk_promotion`) to `SalesFact` (or a bridge table for many‑to‑many).

### Adding a New Fact (e.g., InventorySnapshot)

* Follow the same pattern: surrogate keys to dimensions (Product, Store, Date), additive measures (`units_on_hand`, `unit_cost`), and optional degenerate identifiers.
* Keep the fact class focused on a single grain to avoid ambiguity.

### Using Pydantic for Stricter Validation

If you prefer declarative validation, replace the dataclasses with Pydantic `BaseModel`s:

```python
from pydantic import BaseModel, Field, validator
import datetime as dt

class Customer(BaseModel):
    sk: int = Field(gt=0)
    customer_id: str
    name: str
    email: str
    tier: str = "Bronze"
    address: str = ""
    is_active: bool = True
    valid_from: dt.date = Field(default_factory=dt.date.today)
    valid_to: dt.date = dt.date(9999, 12, 31)
    is_current: bool = True

    @validator("email")
    def normalize_email(cls, v):
        return v.lower().strip()

    # ... rest as needed
```

Pydantic offers automatic parsing, rich error messages, and integration with tools like FastAPI—use it when you need schema validation at API boundaries.

---

## 8. Summary Checklist (Pythonic OOP Modeling)

- [ ] **Identify grains** – decide the level of detail for each fact and dimension.
- [ ] **Choose surrogate keys** – simple integer (`sk_<entity>`) generated by your ETL (or use database sequences).
- [ ] **Model natural keys** – include them as fields for change detection and look‑ups.
- [ ] **Use dataclasses** (or Pydantic) with type hints.
- [ ] **Validate in `__post_init__`** – raise `ValueError` for illegal states.
- [ ] **Implement `__eq__` and `__hash__`** based on business keys (not surrogate) when objects represent real‑world entities.
- [ ] **Provide factory methods** (`from_source`, `from_date`) to encapsulate transformation logic.
- [ ] **Add properties** for derived, non‑persistent measures.
- [ ] **Keep dimension rows immutable after creation** – treat them as value objects; if you need SCD‑2, create a new instance with updated surrogate key and validity dates.
- [ ] **Write unit tests** for each class, focusing on validation, equality, and factory correctness.
- [ ] **Optionally add navigation helpers** for in‑memory analytics without polluting the core model.
- [ ] **Document assumptions** (e.g., which attributes trigger a new version, which measures are additive).

With this foundation you can proceed to build an ETL layer that:

1. Extracts raw data (CSV, REST API, database).
2. Maps each row to the appropriate dimension/fact instances using the factory methods.
3. Performs change detection (e.g., `Customer.has_changed`) to emit expired rows and new versions.
4. Persists the objects to your target warehouse (via SQLAlchemy, raw INSERT statements, or a bulk‑copy utility) while preserving surrogate key relationships.

--- 

*End of document.*  